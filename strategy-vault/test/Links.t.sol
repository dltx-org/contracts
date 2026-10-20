// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {Vm} from "forge-std/Test.sol";
import {Fixture} from "./utils/Fixture.sol";
import {CombinationFactory} from "../src/CombinationFactory.sol";
import {StrategyHub} from "../src/StrategyHub.sol";
import {VaultBase, VaultState} from "../src/VaultBase.sol";
import {LegConfig, Legs, ParamsTypes, StrategyConfig} from "../src/lib/VaultTypes.sol";
import {MockTokenMessenger, MockTransmitter, walletCred} from "./mocks/Mocks.sol";
import {TestLeg, TestLegExit} from "./mocks/TestLeg.sol";

/// Between the members (amendment 2a, revision 1, §3.5, §3.6; invariants 2–5), on the hub and the test-only
/// leg type, so the suite can play what 2a builds no factory for: a hub with up to four legs, some on this
/// chain and some elsewhere, every member linked to every other. The unit world plays HyperEVM (domain
/// 19); "elsewhere" is Arbitrum (3) and Ethereum (0).
contract LinksTest is Fixture {
    TestLegExit tExit;
    TestLeg code;
    bytes32 constant READY = keccak256("dltx.strategy-vault.ready.v1");
    bytes32 constant EXIT = keccak256("dltx.strategy-vault.exit.v1");

    function setUp() public {
        _world();
        tExit = new TestLegExit();
        code = new TestLeg(address(tExit), address(tExit).codehash);
    }

    function _factory(uint32 hubDomain, uint32[] memory legDomains) internal returns (CombinationFactory) {
        CombinationFactory.LegPin[] memory p = new CombinationFactory.LegPin[](legDomains.length);
        for (uint256 i; i < legDomains.length; ++i) {
            p[i] = CombinationFactory.LegPin(address(code), address(code).codehash, legDomains[i], i == 0 ? Legs.LONG : Legs.SHORT, Legs.VALUE_READ, "TestLeg", "uint256 seven", 1);
        }
        uint32[] memory hubs = new uint32[](1);
        hubs[0] = hubDomain;
        return _factoryWith(hubs, p);
    }

    function _cfg(CombinationFactory f) internal view returns (StrategyConfig memory c) {
        uint256 n = f.legCount();
        c.factory = address(f);
        c.hubDomain = f.hubDomains()[0];
        c.hubParams = abi.encode(_hubParams());
        c.legs = new LegConfig[](n);
        for (uint256 i; i < n; ++i) {
            CombinationFactory.LegPin memory p = f.leg(i);
            c.legs[i] = LegConfig(p.code, p.domain, p.role, abi.encode(uint256(7)));
        }
    }

    /// Creates the members on this chain; `at` is every member's address (0 the hub).
    function _make(CombinationFactory f) internal returns (address[] memory made, address[] memory at) {
        StrategyConfig memory c = _cfg(f);
        uint256 deadline = block.timestamp + 1 days;
        made = f.create(STRATEGY, address(owner), c, deadline, _createSig(walletPk, STRATEGY, c, deadline));
        (at,) = f.memberAddresses(STRATEGY, address(owner), c);
    }

    function _d(uint32 a, uint32 b) internal pure returns (uint32[] memory d) {
        d = new uint32[](2);
        (d[0], d[1]) = (a, b);
    }

    /// The hub and leg 1 here; leg 2 on Arbitrum; leg 3 on Ethereum.
    function _mesh() internal returns (address[] memory made, address[] memory at) {
        uint32[] memory d = new uint32[](3);
        (d[0], d[1], d[2]) = (HYPEREVM_DOMAIN, ARB_DOMAIN, 0);
        return _make(_factory(HYPEREVM_DOMAIN, d));
    }

    /// The hub and two legs, all here.
    function _local() internal returns (address[] memory made) {
        (made,) = _make(_factory(HYPEREVM_DOMAIN, _d(HYPEREVM_DOMAIN, HYPEREVM_DOMAIN)));
    }

    function _deliver(address to, uint32 fromDomain, address from, bytes32 tag) internal {
        transmitter.deliver(to, fromDomain, bytes32(uint256(uint160(from))), abi.encode(tag));
    }

    function _exit(address member) internal {
        uint256 deadline = block.timestamp + 1 hours;
        VaultBase(member).beginExit(deadline, _beginExitSig(STRATEGY, deadline));
    }

    function _b(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    // ── one chain ────────────────────────────────────────────────────────────────────────────────────

    function test_oneChain_everyMemberInOneTransaction_readyByCode_directTransfers_countedPerPair() public {
        uint256 sentBefore = transmitter.sentCount();
        address[] memory made = _local();
        assertEq(made.length, 3);
        StrategyHub hub = StrategyHub(made[0]);
        TestLeg one = TestLeg(made[1]);
        TestLeg two = TestLeg(made[2]);
        assertTrue(made[1] != made[2], "one code, one chain, two legs: the index salts them apart");
        assertEq(hub.localLinks(), 3);
        assertTrue(hub.ready(0) && hub.ready(1) && one.ready(0) && one.ready(1));
        assertEq(transmitter.sentCount(), sentBefore, "no Circle message between members of one chain");
        usdc.mint(address(hub), 100e6);
        vm.prank(key);
        hub.send(0, 60e6, true, 1e6);
        assertEq(usdc.balanceOf(address(one)), 60e6, "a transfer, no fee");
        assertEq(hub.sentTo(0), 60e6);
        assertEq(one.receivedFrom(0), 60e6);
        // a leg pays its sister leg directly, never through the hub
        vm.prank(key);
        one.send(1, 25e6, false, 0);
        assertEq(usdc.balanceOf(address(two)), 25e6);
        assertEq(usdc.balanceOf(address(hub)), 40e6);
        assertEq(one.sentTo(1), 25e6);
        assertEq(two.receivedFrom(1), 25e6, "leg 2's link 1 is leg 1");
        vm.prank(key);
        two.send(0, 5e6, false, 0);
        assertEq(hub.receivedFrom(1), 5e6);
        assertEq(messenger.burnCount(), 0);
        vm.prank(key);
        vm.expectRevert(VaultState.NotReady.selector);
        one.send(2, 1, false, 0); // past the links
    }

    /// `receiveLocal` pulls only from a member of this chain.
    function test_receiveLocal_onlyFromALocalLink() public {
        (address[] memory made, address[] memory at) = _mesh();
        usdc.mint(stranger, 10e6);
        vm.startPrank(stranger);
        usdc.approve(made[0], 10e6);
        vm.expectRevert(VaultState.BadMessage.selector);
        VaultBase(made[0]).receiveLocal(10e6);
        vm.stopPrank();
        vm.prank(at[2]); // a link, but on Arbitrum
        vm.expectRevert(VaultState.BadMessage.selector);
        VaultBase(made[0]).receiveLocal(1);
    }

    /// Invariant 4 started from each member in turn, by the owner's signature and by the stopped group:
    /// the member that entered tells every other (directly, here); the legs send everything to the hub;
    /// the hub pays the withdrawal address the total.
    function test_oneChain_exitTerminates_fromEachMember() public {
        for (uint256 run; run < 6; ++run) {
            uint256 from = run % 3;
            uint256 snap = vm.snapshotState();
            address[] memory made = _local();
            for (uint256 i; i < 3; ++i) usdc.mint(made[i], (i + 1) * 10e6);
            if (run < 3) {
                _exit(made[from]);
            } else {
                vm.warp(vm.getBlockTimestamp() + 7 days);
                vm.prank(stranger);
                VaultBase(made[from]).beginExitStopped();
            }
            for (uint256 i; i < 3; ++i) {
                assertTrue(VaultBase(made[i]).exiting(), "every member, at once");
                assertEq(VaultBase(made[i]).toldPending(), 0);
            }
            vm.startPrank(stranger);
            TestLegExit(made[1]).exitStep();
            TestLegExit(made[2]).exitStep();
            StrategyHub(made[0]).exitStep();
            vm.stopPrank();
            for (uint256 i; i < 3; ++i) assertEq(usdc.balanceOf(made[i]), 0);
            assertEq(usdc.balanceOf(withdrawalTo), 60e6);
            assertEq(StrategyHub(made[0]).receivedFrom(0), 20e6);
            assertEq(StrategyHub(made[0]).receivedFrom(1), 30e6);
            vm.revertToState(snap);
        }
    }

    /// Four legs (the most), all here: every member holds four links; the exit ends at the withdrawal
    /// address, the hub paying as the legs' money arrives.
    function test_fourLegs_exitPaidAsItArrives() public {
        uint32[] memory d = new uint32[](4);
        for (uint256 i; i < 4; ++i) d[i] = HYPEREVM_DOMAIN;
        (address[] memory made,) = _make(_factory(HYPEREVM_DOMAIN, d));
        assertEq(made.length, 5);
        for (uint256 i; i < 5; ++i) {
            assertEq(VaultBase(made[i]).linkCount(), 4);
            usdc.mint(made[i], (i + 1) * 10e6);
        }
        _exit(made[3]); // a leg's owner
        vm.startPrank(stranger);
        StrategyHub(made[0]).exitStep();
        assertEq(usdc.balanceOf(withdrawalTo), 10e6, "what the hub held, at once");
        TestLegExit(made[1]).exitStep();
        TestLegExit(made[2]).exitStep();
        StrategyHub(made[0]).exitStep();
        TestLegExit(made[3]).exitStep();
        TestLegExit(made[4]).exitStep();
        StrategyHub(made[0]).exitStep();
        StrategyHub(made[0]).exitStep(); // nothing left: harmless
        vm.stopPrank();
        assertEq(usdc.balanceOf(withdrawalTo), 150e6);
    }

    // ── members on other chains ──────────────────────────────────────────────────────────────────────

    function test_mesh_localMembersCreated_readySentToEveryRemoteOne() public {
        uint256 sentBefore = transmitter.sentCount();
        (address[] memory made, address[] memory at) = _mesh();
        assertEq(made.length, 2, "the hub and leg 1");
        StrategyHub hub = StrategyHub(made[0]);
        assertEq(hub.linkCount(), 3);
        assertEq(hub.links(0), at[1]);
        assertEq(hub.links(1), at[2]);
        assertEq(hub.links(2), at[3]);
        assertEq(hub.linkDomains(2), 0);
        TestLeg one = TestLeg(made[1]);
        assertEq(one.links(0), at[0], "a leg's link 0 is its hub");
        assertEq(one.links(1), at[2]);
        assertEq(one.links(2), at[3]);
        // each local member's READY to legs 2 and 3, finalized, from itself
        assertEq(transmitter.sentCount(), sentBefore + 4);
        MockTransmitter.Sent memory m = transmitter.sent(sentBefore);
        assertEq(m.destinationDomain, ARB_DOMAIN);
        assertEq(m.recipient, _b(at[2]));
        assertEq(m.minFinalityThreshold, 2000);
        assertEq(m.body, abi.encode(READY));
        assertEq(m.sender, address(hub));
        assertEq(transmitter.sent(sentBefore + 1).destinationDomain, 0);
        assertEq(transmitter.sent(sentBefore + 2).sender, address(one));
        // leg 2 is not ready until its READY arrives; then the hub may send it money, a mint bound to it
        assertTrue(hub.ready(0));
        assertFalse(hub.ready(1));
        usdc.mint(address(hub), 100e6);
        vm.prank(key);
        vm.expectRevert(VaultState.NotReady.selector);
        hub.send(1, 10e6, false, 0);
        _deliver(address(hub), ARB_DOMAIN, at[2], READY);
        assertTrue(hub.ready(1));
        assertFalse(hub.ready(2));
        assertFalse(one.ready(1), "each member hears its own READY");
        vm.prank(key);
        hub.send(1, 10e6, false, 0);
        MockTokenMessenger.Burn memory b = messenger.burn(0);
        assertEq(b.destinationDomain, ARB_DOMAIN);
        assertEq(b.mintRecipient, _b(at[2]));
        assertEq(b.destinationCaller, _b(at[2]), "only the recipient completes the mint");
        assertEq(b.amount, 10e6);
        assertEq(b.minFinalityThreshold, 2000);
        assertEq(hub.sentTo(1), 10e6);
        // a leg pays a remote sister leg directly
        _deliver(address(one), ARB_DOMAIN, at[2], READY);
        usdc.mint(address(one), 20e6);
        vm.prank(key);
        one.send(1, 20e6, false, 0);
        b = messenger.burn(1);
        assertEq(b.mintRecipient, _b(at[2]));
        assertEq(b.destinationCaller, _b(at[2]));
        assertEq(b.from, address(one));
    }

    function test_ready_refusals() public {
        (address[] memory made, address[] memory at) = _mesh();
        address hub = made[0];
        bytes memory ready = abi.encode(READY);
        // not through Circle's transmitter
        vm.expectRevert(VaultState.BadMessage.selector);
        VaultBase(hub).handleReceiveFinalizedMessage(ARB_DOMAIN, _b(at[2]), 2000, ready);
        // not a link; a link's address from another domain; a link on this chain (they never message)
        vm.expectRevert(VaultState.BadMessage.selector);
        _deliver(hub, ARB_DOMAIN, stranger, READY);
        vm.expectRevert(VaultState.BadMessage.selector);
        _deliver(hub, 0, at[2], READY);
        vm.expectRevert(VaultState.BadMessage.selector);
        _deliver(hub, HYPEREVM_DOMAIN, at[1], READY);
        // an unknown tag; a READY with a tail
        vm.expectRevert(VaultState.BadMessage.selector);
        _deliver(hub, ARB_DOMAIN, at[2], keccak256("other"));
        vm.expectRevert(VaultState.BadMessage.selector);
        transmitter.deliver(hub, ARB_DOMAIN, _b(at[2]), abi.encode(READY, uint256(1)));
        // below finalized, by either handler
        vm.startPrank(TRANSMITTER);
        vm.expectRevert(VaultState.BadMessage.selector);
        VaultBase(hub).handleReceiveFinalizedMessage(ARB_DOMAIN, _b(at[2]), 1000, ready);
        vm.expectRevert(VaultState.BadMessage.selector);
        VaultBase(hub).handleReceiveUnfinalizedMessage(ARB_DOMAIN, _b(at[2]), 2000, ready);
        // a sender word with dirty high bits is not an address
        vm.expectRevert(VaultState.BadMessage.selector);
        VaultBase(hub).handleReceiveFinalizedMessage(ARB_DOMAIN, bytes32(uint256(uint160(at[2])) | (uint256(1) << 200)), 2000, ready);
        vm.stopPrank();
        assertEq(VaultBase(hub).readyLinks(), 0);
    }

    /// Circle paused at creation: the members exist all the same; anyone announces again once it is back.
    function test_announceReady_afterAFailedFirstSend() public {
        transmitter.setPaused(true);
        uint256 sentBefore = transmitter.sentCount();
        (address[] memory made,) = _mesh();
        assertEq(transmitter.sentCount(), sentBefore, "nothing went");
        VaultBase hub = VaultBase(made[0]);
        vm.expectRevert(bytes("Pausable: paused"));
        hub.announceReady(1);
        transmitter.setPaused(false);
        vm.prank(stranger);
        hub.announceReady(1);
        assertEq(transmitter.sentCount(), sentBefore + 1);
        assertEq(transmitter.sent(sentBefore).body, abi.encode(READY));
        // never to a link on this chain, nor past the links
        vm.expectRevert(VaultState.NotAllowed.selector);
        hub.announceReady(0);
        vm.expectRevert(VaultState.NotAllowed.selector);
        hub.announceReady(3);
        // in exit too
        _exit(address(hub));
        hub.announceReady(2);
    }

    /// Circle refusing a READY at creation is on chain (`ReadyPending`), not silent.
    function test_ready_refusedByCircle_isReadyPending() public {
        transmitter.setPaused(true);
        vm.recordLogs();
        (address[] memory made,) = _make(_factory(HYPEREVM_DOMAIN, _d(HYPEREVM_DOMAIN, ARB_DOMAIN)));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool pending;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == made[0] && logs[i].topics[0] == keccak256("ReadyPending(uint8)")) pending = true;
            assertTrue(logs[i].topics[0] != keccak256("ReadySent(uint8)"), "nothing went");
        }
        assertTrue(pending);
    }

    // ── the exit's spreading: the member that entered by itself tells every other; a told one tells nobody ──

    function test_exit_hubTellsEveryLeg() public {
        (address[] memory made, address[] memory at) = _mesh();
        VaultBase hub = VaultBase(made[0]);
        uint256 sentBefore = transmitter.sentCount();
        _exit(address(hub));
        assertTrue(VaultBase(made[1]).exiting(), "the local leg, directly");
        assertEq(transmitter.sentCount(), sentBefore + 2, "the two others, by Circle");
        MockTransmitter.Sent memory m = transmitter.sent(sentBefore);
        assertEq(m.recipient, _b(at[2]));
        assertEq(m.body, abi.encode(EXIT));
        assertEq(m.minFinalityThreshold, 1000);
        assertEq(transmitter.sent(sentBefore + 1).recipient, _b(at[3]));
        assertEq(hub.toldPending(), 0);
    }

    /// Told by a member (Circle's message), the hub tells nobody — not even its local leg: the member that
    /// entered by itself tells every member itself.
    function test_exit_toldByAMessage_tellsNobody() public {
        (address[] memory made, address[] memory at) = _mesh();
        VaultBase hub = VaultBase(made[0]);
        uint256 sentBefore = transmitter.sentCount();
        _deliver(address(hub), ARB_DOMAIN, at[2], EXIT);
        assertTrue(hub.exiting());
        assertFalse(VaultBase(made[1]).exiting(), "leg 2 tells leg 1 itself");
        assertEq(transmitter.sentCount(), sentBefore);
        assertEq(hub.toldPending(), 0);
        _deliver(made[1], ARB_DOMAIN, at[2], EXIT);
        assertTrue(VaultBase(made[1]).exiting());
        _deliver(made[1], ARB_DOMAIN, at[2], EXIT); // a duplicate: harmless
    }

    /// A local leg entering by its owner: the hub directly (and it tells nobody), the remote legs by Circle.
    function test_exit_localLegByOwner_tellsEveryMember() public {
        (address[] memory made, address[] memory at) = _mesh();
        uint256 sentBefore = transmitter.sentCount();
        _exit(made[1]);
        assertTrue(VaultBase(made[0]).exiting());
        assertEq(transmitter.sentCount(), sentBefore + 2, "legs 2 and 3, from leg 1 only");
        assertEq(transmitter.sent(sentBefore).sender, made[1]);
        assertEq(transmitter.sent(sentBefore).recipient, _b(at[2]));
        assertEq(transmitter.sent(sentBefore + 1).sender, made[1]);
        assertEq(VaultBase(made[1]).toldPending(), 0);
        assertEq(VaultBase(made[0]).toldPending(), 0);
    }

    function test_exit_circlePaused_committedLocally_notifyLinkPerLink() public {
        (address[] memory made,) = _mesh();
        VaultBase hub = VaultBase(made[0]);
        transmitter.setPaused(true);
        _exit(address(hub));
        assertTrue(hub.exiting());
        assertTrue(VaultBase(made[1]).exiting(), "the local leg needs no Circle");
        assertEq(hub.toldPending(), 6, "links 1 and 2 pending");
        vm.expectRevert(VaultState.NotAllowed.selector);
        hub.notifyLink(0);
        vm.expectRevert(bytes("Pausable: paused"));
        hub.notifyLink(1);
        transmitter.setPaused(false);
        vm.prank(stranger);
        hub.notifyLink(1);
        assertEq(hub.toldPending(), 4);
        vm.expectRevert(VaultState.NotAllowed.selector);
        hub.notifyLink(1);
        hub.notifyLink(2);
        assertEq(hub.toldPending(), 0);
    }

    /// A link not yet told that enters its exit by another way (its own message) is not pending any more.
    function test_exit_pendingLinkThatTellsUs_isCleared() public {
        (address[] memory made, address[] memory at) = _mesh();
        VaultBase hub = VaultBase(made[0]);
        transmitter.setPaused(true);
        _exit(address(hub));
        assertEq(hub.toldPending(), 6);
        transmitter.setPaused(false);
        _deliver(address(hub), ARB_DOMAIN, at[2], EXIT); // leg 2 entered its exit and says so
        assertEq(hub.toldPending(), 4);
    }

    function test_legExit_onlyFromALocalLink() public {
        (address[] memory made, address[] memory at) = _mesh();
        vm.prank(stranger);
        vm.expectRevert(VaultState.BadMessage.selector);
        VaultBase(made[0]).legExit();
        vm.prank(at[2]); // a link, but on Arbitrum: it speaks through Circle
        vm.expectRevert(VaultState.BadMessage.selector);
        VaultBase(made[0]).legExit();
        assertFalse(VaultBase(made[0]).exiting());
    }

    /// Too little gas to tell a link across chains: the entry reverts, rather than committing with the
    /// link silently skipped (a gas estimate can't buy a skipped message: §14).
    function test_exit_tooLittleGasToTellALink_reverts() public {
        (address[] memory made,) = _make(_factory(HYPEREVM_DOMAIN, _d(HYPEREVM_DOMAIN, ARB_DOMAIN)));
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _beginExitSig(STRATEGY, deadline);
        vm.expectRevert(VaultState.GasTooLow.selector);
        VaultBase(made[0]).beginExit{gas: 220_000}(deadline, sig);
        assertFalse(VaultBase(made[0]).exiting());
        VaultBase(made[0]).beginExit(deadline, sig);
        assertTrue(VaultBase(made[0]).exiting());
        assertEq(VaultBase(made[0]).toldPending(), 0);
    }

    /// Invariant 2's exemption: a leg's exit sends its remote hub everything with no READY from it, the
    /// mint bound to the hub.
    function test_exit_legToItsRemoteHub_exemptFromReadiness() public {
        (address[] memory made, address[] memory at) = _make(_factory(ARB_DOMAIN, _d(HYPEREVM_DOMAIN, ARB_DOMAIN)));
        assertEq(made.length, 1, "leg 1 alone here");
        TestLeg one = TestLeg(made[0]);
        assertFalse(one.ready(0));
        usdc.mint(address(one), 40e6);
        vm.prank(key);
        vm.expectRevert(VaultState.NotReady.selector);
        one.send(0, 1e6, false, 0); // the key waits for readiness
        _exit(address(one));
        vm.prank(stranger);
        TestLegExit(address(one)).exitStep();
        MockTokenMessenger.Burn memory b = messenger.burn(0);
        assertEq(b.amount, 40e6);
        assertEq(b.destinationDomain, ARB_DOMAIN);
        assertEq(b.mintRecipient, _b(at[0]));
        assertEq(b.destinationCaller, _b(at[0]));
        assertEq(b.minFinalityThreshold, 2000);
        assertEq(one.sentTo(0), 40e6);
        // Circle paused: nothing goes, nothing reverts, the next step retries
        usdc.mint(address(one), 5e6);
        messenger.setPaused(true);
        TestLegExit(address(one)).exitStep();
        assertEq(usdc.balanceOf(address(one)), 5e6);
        assertEq(one.sentTo(0), 40e6);
    }

    /// The execution key's sends stop in exit.
    function test_keySends_blockedInExit() public {
        address[] memory made = _local();
        usdc.mint(made[0], 10e6);
        _exit(made[0]);
        vm.prank(key);
        vm.expectRevert(VaultState.Exiting.selector);
        StrategyHub(made[0]).send(0, 1e6, false, 0);
        vm.prank(key);
        vm.expectRevert(VaultState.Exiting.selector);
        TestLeg(made[1]).send(0, 1e6, false, 0);
    }

    // ── mints completed by their receiver, counted per pair (decision 44) ────────────────────────────

    uint256 nonce;

    /// A CCTP V2 burn message: the 148-byte header, then BurnMessageV2.
    function _mint(uint32 source, address caller, address recipient, uint256 amount, address from, uint256 fee)
        internal
        returns (bytes memory)
    {
        bytes memory header = abi.encodePacked(
            uint32(1), source, HYPEREVM_DOMAIN, bytes32(++nonce), _b(TOKEN_MESSENGER), _b(TOKEN_MESSENGER), _b(caller), uint32(1000), uint32(1000)
        );
        bytes memory body = abi.encodePacked(
            uint32(1), _b(USDC), _b(recipient), amount, _b(from), uint256(fee), uint256(fee), uint256(0)
        );
        return bytes.concat(header, body);
    }

    function test_receiveMint_countsAMembersBurn_grossAndFee_anyoneAnyState() public {
        (address[] memory made, address[] memory at) = _mesh();
        StrategyHub hub = StrategyHub(made[0]);
        // paused and revoked: still completed
        vm.prank(key);
        hub.pause(true);
        uint256 deadline = block.timestamp + 1 hours;
        hub.ownerAction(1, address(0), walletCred(wallet), deadline, _actionSig(address(hub), 1, address(0), 0, deadline));
        vm.prank(stranger);
        hub.receiveMint(_mint(ARB_DOMAIN, address(hub), address(hub), 10e6, at[2], 1e4), "");
        assertEq(usdc.balanceOf(address(hub)), 10e6 - 1e4);
        assertEq(hub.receivedFrom(1), 10e6, "gross");
        assertEq(hub.feesFrom(1), 1e4);
        // a leg too, through its module, in exit
        TestLeg one = TestLeg(made[1]);
        _exit(address(one));
        TestLegExit(address(one)).receiveMint(_mint(0, address(one), address(one), 3e6, at[3], 0), "");
        assertEq(one.receivedFrom(2), 3e6);
        // a stranger's burn bound to the hub: accepted, uncounted
        hub.receiveMint(_mint(ARB_DOMAIN, address(hub), address(hub), 2e6, stranger, 1e3), "");
        assertEq(hub.receivedFromOthers(), 2e6 - 1e3);
        // a member's address from the wrong domain is not that member
        hub.receiveMint(_mint(0, address(hub), address(hub), 1e6, at[2], 0), "");
        assertEq(hub.receivedFrom(1), 10e6);
        assertEq(hub.receivedFromOthers(), 3e6 - 1e3);
    }

    /// Across chains, both sides counted: what one member burned (`sentTo`) and what the other completed
    /// (`receivedFrom`, gross) agree once it landed, whatever Circle's fee (`feesFrom`). Both chains are
    /// played in one EVM: the hub created as if on Arbitrum, leg 1 on HyperEVM.
    function test_crossChain_bothSidesCounted() public {
        (address[] memory made, address[] memory at) = _make(_factory(ARB_DOMAIN, _d(HYPEREVM_DOMAIN, ARB_DOMAIN)));
        TestLeg one = TestLeg(made[0]);
        transmitter.setLocalDomain(ARB_DOMAIN);
        StrategyConfig memory c = _cfg(CombinationFactory(one.factory()));
        uint256 deadline = block.timestamp + 1 days;
        StrategyHub hub = StrategyHub(
            CombinationFactory(one.factory()).create(STRATEGY, address(owner), c, deadline, _createSig(walletPk, STRATEGY, c, deadline))[0]
        );
        assertEq(address(hub), at[0]);
        transmitter.setLocalDomain(HYPEREVM_DOMAIN);
        _deliver(address(one), ARB_DOMAIN, address(hub), READY);
        usdc.mint(address(one), 300e6);
        vm.prank(key);
        one.send(0, 300e6, true, 0.15e6);
        MockTokenMessenger.Burn memory b = messenger.burn(0);
        assertEq(b.destinationCaller, _b(address(hub)));
        // Circle executes a smaller fee than the maximum; the mint lands on Arbitrum
        transmitter.setLocalDomain(ARB_DOMAIN);
        bytes memory m = abi.encodePacked(
            abi.encodePacked(uint32(1), HYPEREVM_DOMAIN, ARB_DOMAIN, bytes32(++nonce), _b(TOKEN_MESSENGER), _b(TOKEN_MESSENGER), b.destinationCaller, uint32(1000), uint32(1000)),
            abi.encodePacked(uint32(1), _b(USDC), b.mintRecipient, b.amount, _b(address(one)), b.maxFee, uint256(0.1e6), uint256(0))
        );
        vm.prank(stranger);
        hub.receiveMint(m, "");
        assertEq(one.sentTo(0), 300e6);
        assertEq(hub.receivedFrom(0), 300e6, "gross: the sender's own count");
        assertEq(hub.feesFrom(0), 0.1e6);
        assertEq(one.sentTo(0) - hub.receivedFrom(0), 0, "nothing in flight once it landed");
        assertEq(usdc.balanceOf(address(hub)), 300e6 - 0.1e6);
    }

    function test_receiveMint_refusals() public {
        (address[] memory made, address[] memory at) = _mesh();
        StrategyHub hub = StrategyHub(made[0]);
        // bound to another caller; minted to another recipient; meant for another chain; too short
        bytes memory m = _mint(ARB_DOMAIN, made[1], address(hub), 1e6, at[2], 0);
        vm.expectRevert(VaultState.BadMessage.selector);
        hub.receiveMint(m, "");
        m = _mint(ARB_DOMAIN, address(hub), made[1], 1e6, at[2], 0);
        vm.expectRevert(VaultState.BadMessage.selector);
        hub.receiveMint(m, "");
        m = _mint(ARB_DOMAIN, address(hub), address(hub), 1e6, at[2], 0);
        transmitter.setLocalDomain(ARB_DOMAIN);
        vm.expectRevert(VaultState.BadMessage.selector);
        hub.receiveMint(m, "");
        transmitter.setLocalDomain(HYPEREVM_DOMAIN);
        vm.expectRevert(VaultState.BadMessage.selector);
        hub.receiveMint(new bytes(375), "");
        // the security review's C-1: a general message laid out as a burn, to a recipient other than the
        // TokenMessenger (Circle attests it and calls that recipient; nothing is minted)
        bytes memory forged = _mint(ARB_DOMAIN, address(hub), address(hub), type(uint256).max - 1e6, at[2], 0);
        assembly ("memory-safe") {
            mstore(add(forged, add(32, 76)), 0xbad) // header recipient: not the TokenMessenger
        }
        vm.expectRevert(VaultState.BadMessage.selector);
        hub.receiveMint(forged, "");
        // once only: Circle refuses the nonce again
        hub.receiveMint(m, "");
        vm.expectRevert(bytes("Nonce already used"));
        hub.receiveMint(m, "");
        assertEq(hub.receivedFrom(1), 1e6);
    }

    // ── the daily fee budget (invariant 6) ───────────────────────────────────────────────────────────

    /// Fast sends' fees within a share of the member's USDC per 24 hours: two day buckets, so a day's
    /// spend still counts the next day.
    function test_feeBudget_twoDayWindow() public {
        (address[] memory made, address[] memory at) = _make(_factory(HYPEREVM_DOMAIN, _d(HYPEREVM_DOMAIN, ARB_DOMAIN)));
        TestLeg one = TestLeg(made[1]);
        _deliver(address(one), ARB_DOMAIN, at[2], READY);
        uint256 t0 = (vm.getBlockTimestamp() / 1 days + 1) * 1 days; // a day's start (via-IR may keep
        vm.warp(t0); // `block.timestamp` across a warp)
        // the test leg: fast at most 50 bp, fees at most 100 bp of its USDC
        usdc.mint(address(one), 100e6);
        vm.prank(key);
        one.send(1, 100e6, true, 0.5e6);
        usdc.mint(address(one), 100e6);
        vm.prank(key);
        one.send(1, 100e6, true, 0.5e6); // 1e6: the budget, exactly
        usdc.mint(address(one), 100e6);
        vm.prank(key);
        vm.expectRevert(VaultState.OverFeeBudget.selector);
        one.send(1, 100e6, true, 0.5e6);
        vm.prank(key);
        vm.expectRevert(VaultState.FeeAboveCap.selector);
        one.send(1, 100e6, true, 0.5e6 + 1);
        // standard finality pays Circle's minimum only: none here
        vm.prank(key);
        one.send(1, 50e6, false, 0);
        vm.warp(t0 + 1 days);
        vm.prank(key);
        vm.expectRevert(VaultState.OverFeeBudget.selector);
        one.send(1, 50e6, true, 0.25e6);
        vm.warp(t0 + 2 days);
        vm.prank(key);
        one.send(1, 50e6, true, 0.25e6);
    }

    // ── amendment 2d §5.2: the hub's exit routes to a leg beside it only what the leg states it owes ────
    // (2a invariant 4 as amended: in exit, legs send to the hub only, and the hub sends to a leg only what
    // that leg's `exitDebt()` states, before paying the owner)

    event ExitRouteFailed(uint8 indexed link, bytes reason);
    event ExitSettleFailed(bytes reason);

    /// The hub and two legs here, 1,000 USDC of capital in the hub, leg 1 stating 300 owed, in exit.
    function _routed() internal returns (StrategyHub hub, TestLeg l1, TestLeg l2) {
        address[] memory made = _local();
        hub = StrategyHub(made[0]);
        l1 = TestLeg(payable(made[1]));
        l2 = TestLeg(payable(made[2]));
        usdc.mint(address(hub), 1_000e6);
        l1.setOwed(300e6);
        _exit(address(hub));
    }

    function test_2d_route_onlyWhatTheLegStates_thenThePayout() public {
        (StrategyHub hub, TestLeg l1, TestLeg l2) = _routed();
        assertEq(TestLegExit(address(l1)).exitDebt(), 300e6);
        hub.exitStep();
        assertEq(usdc.balanceOf(address(l1)), 300e6, "the debt it stated, first");
        assertEq(hub.sentTo(0), 300e6);
        assertEq(l1.receivedFrom(0), 300e6, "counted on both sides");
        assertEq(usdc.balanceOf(address(l2)), 0, "a leg stating nothing gets nothing");
        assertEq(hub.sentTo(1), 0);
        assertEq(usdc.balanceOf(withdrawalTo), 700e6, "the rest to the owner, no fee on capital");
        assertEq(hub.booked(), 0);
        // the leg's debt is covered: nothing more routed, and its surplus comes back to the hub
        l1.setOwed(0);
        usdc.mint(address(hub), 50e6);
        hub.exitStep();
        assertEq(hub.sentTo(0), 300e6);
        assertEq(usdc.balanceOf(withdrawalTo), 750e6);
        TestLegExit(address(l1)).exitStep();
        assertEq(hub.receivedFrom(0), 300e6);
        hub.exitStep();
        assertEq(usdc.balanceOf(withdrawalTo), 1_050e6);
    }

    /// More stated than the hub holds: everything it holds goes to the leg, nothing to the owner yet.
    function test_2d_route_cappedAtTheFreeCash() public {
        (StrategyHub hub, TestLeg l1,) = _routed();
        l1.setOwed(5_000e6);
        hub.exitStep();
        assertEq(usdc.balanceOf(address(l1)), 1_000e6);
        assertEq(usdc.balanceOf(withdrawalTo), 0);
    }

    /// No withdrawal address: the debt is still repaid (it needs none); the rest waits.
    function test_2d_route_needsNoWithdrawalAddress() public {
        (StrategyHub hub, TestLeg l1,) = _routed();
        owner.setWithdrawalAddress(address(0));
        hub.exitStep();
        assertEq(usdc.balanceOf(address(l1)), 300e6);
        assertEq(usdc.balanceOf(address(hub)), 700e6);
    }

    /// A hub that entered by a member's message told nobody: its step puts the leg beside it in exit
    /// first, and routes only once it is (outside the exit a leg states nothing).
    function test_2d_hubStep_tellsTheLegBeside_beforeRouting() public {
        (address[] memory made, address[] memory at) = _mesh();
        StrategyHub hub = StrategyHub(made[0]);
        TestLeg l1 = TestLeg(payable(made[1]));
        l1.setOwed(100e6);
        assertEq(TestLegExit(address(l1)).exitDebt(), 0, "nothing stated outside the exit");
        usdc.mint(address(hub), 500e6);
        _deliver(address(hub), ARB_DOMAIN, at[2], EXIT);
        assertTrue(hub.exiting());
        assertFalse(l1.exiting());
        uint256 sentBefore = transmitter.sentCount();
        hub.exitStep();
        assertTrue(l1.exiting(), "told by the hub's step");
        assertEq(transmitter.sentCount(), sentBefore, "nobody else told: the remote legs by their own path");
        assertEq(usdc.balanceOf(address(l1)), 100e6);
        assertEq(hub.sentTo(1), 0, "never a remote leg");
        assertEq(hub.sentTo(2), 0);
        assertEq(usdc.balanceOf(withdrawalTo), 400e6);
    }

    /// USDC refusing the leg: that route rolls back alone (logged), the owner is paid.
    function test_2d_routeFails_alone_ownerPaid() public {
        (StrategyHub hub, TestLeg l1,) = _routed();
        usdc.setFrozen(address(l1), true);
        vm.expectEmit(true, false, false, false, address(hub));
        emit ExitRouteFailed(0, "");
        hub.exitStep();
        assertEq(hub.sentTo(0), 0, "its counters rolled back");
        assertEq(l1.receivedFrom(0), 0);
        assertEq(usdc.balanceOf(withdrawalTo), 1_000e6);
        assertEq(hub.booked(), 0);
    }

    /// A withdrawal address USDC refuses: the route stands, the payout rolls back alone (logged), its
    /// fee accounting with it; a later step pays once the address takes it.
    function test_2d_settleFails_alone_routeStands() public {
        (StrategyHub hub, TestLeg l1,) = _routed();
        usdc.setFrozen(withdrawalTo, true);
        vm.expectEmit(false, false, false, false, address(hub));
        emit ExitSettleFailed("");
        hub.exitStep();
        assertEq(usdc.balanceOf(address(l1)), 300e6, "the route stands");
        assertEq(hub.exitPaid(), 0);
        assertEq(hub.exitFeePaid(), 0);
        assertEq(usdc.balanceOf(address(hub)), 700e6);
        assertEq(hub.booked(), 700e6);
        usdc.setFrozen(withdrawalTo, false);
        l1.setOwed(0); // it repaid with what was routed
        hub.exitStep();
        assertEq(usdc.balanceOf(withdrawalTo), 700e6);
        assertEq(hub.exitPaid(), 700e6);
    }

    /// A step with too little gas for a route or the payout reverts: a gas estimate can't buy a skip.
    function test_2d_hubStep_tooLittleGas_reverts() public {
        (StrategyHub hub,,) = _routed();
        vm.expectRevert(VaultState.GasTooLow.selector);
        hub.exitStep{gas: 500_000}();
        hub.exitStep{gas: 3_000_000}();
        assertEq(usdc.balanceOf(withdrawalTo), 700e6);
        // a hub with no leg beside it: the payout's own admission
        (address[] memory made,) = _make(_factory(HYPEREVM_DOMAIN, _d(ARB_DOMAIN, 0)));
        StrategyHub alone = StrategyHub(made[0]);
        usdc.mint(address(alone), 10e6);
        _exit(address(alone));
        vm.expectRevert(VaultState.GasTooLow.selector);
        alone.exitStep{gas: 300_000}();
        alone.exitStep{gas: 1_000_000}();
        assertEq(usdc.balanceOf(withdrawalTo), 710e6);
    }

    /// A leg type whose `exitDebt()` answers success with no word, or less than one, reads as nothing owed
    /// (Codex's code review: the answer's length is read after the call, not before it).
    function test_2d_route_emptyOrShortAnswer_readsZero() public {
        (StrategyHub hub, TestLeg l1,) = _routed();
        vm.mockCall(address(l1), abi.encodeWithSignature("exitDebt()"), bytes(""));
        hub.exitStep();
        assertEq(hub.sentTo(0), 0, "an empty answer");
        assertEq(usdc.balanceOf(withdrawalTo), 1_000e6);
        usdc.mint(address(hub), 100e6);
        vm.mockCall(address(l1), abi.encodeWithSignature("exitDebt()"), abi.encodePacked(uint128(type(uint128).max)));
        hub.exitStep();
        assertEq(hub.sentTo(0), 0, "a truncated answer");
        assertEq(usdc.balanceOf(withdrawalTo), 1_100e6);
    }

    /// The settlement failing rolls back its fee too: with a fee address and profit above the exit's base,
    /// a withdrawal address USDC refuses leaves the fee unpaid and unrecorded, the route standing; the next
    /// step, the address payable again, charges it once.
    function test_2d_settleFails_feeRolledBack() public {
        address treasury = makeAddr("treasury");
        vm.prank(recovery);
        registry.proposeFeeAddress(treasury);
        vm.prank(treasury);
        registry.acceptFeeAddress();
        (StrategyHub hub, TestLeg l1, TestLeg l2) = _routed(); // 1,000 of capital, leg 1 owing 300
        usdc.mint(address(l2), 500e6); // earned on leg 2: profit once it reaches the hub
        TestLegExit(address(l2)).exitStep(); // to the hub, a counted move: booked, not capital
        assertEq(hub.receivedFrom(1), 500e6);
        usdc.setFrozen(withdrawalTo, true);
        hub.exitStep();
        assertEq(hub.sentTo(0), 300e6, "the route stands");
        assertEq(usdc.balanceOf(treasury), 0, "the fee transfer undone");
        assertEq(hub.exitFeePaid(), 0, "and its accounting");
        assertEq(hub.feeOwed(), 0);
        assertEq(usdc.balanceOf(address(hub)), 1_200e6);
        usdc.setFrozen(withdrawalTo, false);
        l1.setOwed(0);
        hub.exitStep();
        // realised 1,200 above the base of 1,000: 15 % of 200
        assertEq(hub.exitFeePaid(), 30e6);
        assertEq(usdc.balanceOf(treasury), 30e6);
        assertEq(usdc.balanceOf(withdrawalTo), 1_170e6);
    }

    /// Only the hub itself calls its route and its settlement.
    function test_2d_routeAndSettle_selfOnly() public {
        (StrategyHub hub,,) = _routed();
        vm.expectRevert(VaultState.NotAllowed.selector);
        hub.exitRoute(0);
        vm.expectRevert(VaultState.NotAllowed.selector);
        hub.exitSettle();
    }

    /// A leg type without `exitDebt()` (the HyperCore leg, beside a hub on HyperEVM) is never routed to:
    /// its fallback refuses the selector, which reads as nothing owed.
    function test_2d_aLegWithoutExitDebt_neverRoutedTo() public {
        uint32[] memory hubs = new uint32[](1);
        hubs[0] = HYPEREVM_DOMAIN;
        CombinationFactory f = _factoryWith(hubs, _pins());
        StrategyConfig memory c = _config();
        c.factory = address(f);
        c.hubDomain = HYPEREVM_DOMAIN;
        uint256 deadline = block.timestamp + 1 days;
        address[] memory made = f.create(STRATEGY, address(owner), c, deadline, _createSig(walletPk, STRATEGY, c, deadline));
        StrategyHub hub = StrategyHub(made[0]);
        address hl = made[1];
        (bool ok,) = hl.staticcall(abi.encodeWithSignature("exitDebt()"));
        assertFalse(ok, "the HyperCore leg has no exitDebt()");
        usdc.mint(address(hub), 100e6);
        _exit(address(hub));
        assertTrue(VaultBase(hl).exiting());
        hub.exitStep();
        assertEq(hub.sentTo(1), 0, "never routed to");
        assertEq(usdc.balanceOf(withdrawalTo), 100e6);
    }
}

