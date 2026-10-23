// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {Credential, DepositAccount, StrategyGrant, Withdrawal} from "../src/DepositAccount.sol";
import {DepositAccountRecord} from "../src/DepositAccountRecord.sol";
import {DepositAccountState} from "../src/DepositAccountState.sol";
import {DepositFactory} from "../src/DepositFactory.sol";
import {DepositAccountRecordV2, DepositAccountV2} from "./fixtures/DepositAccountV2.sol";
import {FixtureVaultFactory, Helpers, MockToken, MockTokenMessenger, MockTransmitter} from "./Helpers.sol";

/// A factory that continues `predecessor` (§A9): all the listing asks of it.
contract SuccessorFactory {
    address public predecessor;

    constructor(address p) {
        predecessor = p;
    }

    function setPredecessor(address p) external {
        predecessor = p;
    }
}

/// A withdrawal address with code: on receiving the native coin it tries to apply the account's
/// pending upgrade, and keeps what it got (the money lock's test, Codex round 1).
contract ApplyingRecipient {
    DepositAccountRecord public account;
    bytes public err;
    bool public tried;

    function set(address a) external {
        account = DepositAccountRecord(a);
    }

    receive() external payable {
        tried = true;
        try account.applyUpgrade() {}
        catch (bytes memory e) {
            err = e;
        }
    }
}

/// Etched at Circle's transmitter on a copy, as the copy's withdrawal address: on receiving the native
/// coin it delivers `body` to the account, so the copy's upgrade handler runs under the money lock.
contract RelayingTransmitter {
    address public account;
    bytes public body;
    bytes public err;

    function set(address a, bytes calldata b) external {
        (account, body) = (a, b);
    }

    receive() external payable {
        try DepositAccountRecord(account).handleReceiveFinalizedMessage(3, bytes32(uint256(uint160(account))), 2000, body) {}
        catch (bytes memory e) {
            err = e;
        }
    }
}

/*
 * owner-upgrades-design.md §3.2–§3.5, §9: the factory's list of versions, the owner's upgrade at the
 * home, the copies following, the code unusable directly, and in-flight state across an upgrade. No
 * fork: Circle's transmitter is a mock etched at its address; version 2 is the test fixture.
 */
contract UpgradeTest is Helpers {
    address constant MT = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;
    address constant TM = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    uint256 constant ARBITRUM = 42161;
    uint256 constant HYPEREVM = 999;
    bytes32 constant BOB = bytes32(uint256(0xB0B));
    bytes32 constant SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    event Upgraded(address indexed implementation);
    event UpgradeScheduled(address indexed implementation, uint256 version, uint256 due);
    event UpgradeCancelled(address indexed implementation, uint256 due);
    event UpgradeIgnored(address indexed implementation, uint64 publishedAt);
    event UpgradePublished(uint32 indexed domain, address indexed implementation);
    event WithdrawalAddressSet(address indexed previous, address indexed next, uint64 version);
    event ImplementationProposed(address indexed implementation, uint256 codeVersion, bytes32 codeHash, uint256 due);
    event ImplementationListed(address indexed implementation, uint256 indexed version);
    event ImplementationWithdrawn(address indexed implementation);

    DepositFactory f;
    DepositAccount a;
    MockTransmitter mt;
    address v2;

    function setUp() public {
        vm.chainId(ARBITRUM);
        f = deployFactory();
        vm.prank(RECOVERY);
        f.setTransferKey(TRANSFER);
        vm.etch(MT, address(new MockTransmitter()).code);
        mt = MockTransmitter(MT);
        a = deployTwo(f, ALICE, WALLET_A, passkey(PASSKEY_A));
        v2 = newV2(f);
    }

    function self(DepositAccount acct) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(address(acct))));
    }

    function slotOf(address acct) internal view returns (address) {
        return address(uint160(uint256(vm.load(acct, SLOT))));
    }

    function deliver(DepositAccount acct, bytes memory body) internal {
        vm.prank(MT);
        rec(acct).handleReceiveFinalizedMessage(3, self(acct), 2000, body);
    }

    // ── the list (§3.2) ──────────────────────────────────────────────────────────────────────

    function test_list_theGenesisIsVersionOne() public view {
        address g = f.genesis();
        assertEq(f.versionOf(g), 1);
        assertEq(f.versions(), 1);
        assertEq(f.latest(), g);
        assertEq(f.implementationAt(1), g);
        assertEq(f.proxyImplementation(), g);
        assertEq(DepositAccount(g).CODE_VERSION(), 1);
        assertEq(DepositAccount(g).factory(), address(f));
        assertEq(DepositAccountRecord(DepositAccount(g).module()).factory(), address(f));
        assertEq(a.implementation(), g, "every account deploys on the genesis");
        assertEq(a.CODE_VERSION(), 1);
    }

    function test_list_proposeAcceptAfterSevenDays() public {
        uint256 due = vm.getBlockTimestamp() + 7 days;
        vm.expectEmit(true, false, false, true, address(f));
        emit ImplementationProposed(v2, 2, v2.codehash, due);
        vm.prank(RECOVERY);
        f.proposeImplementation(v2);
        (uint64 pDue, bytes32 pHash) = f.proposals(v2);
        assertEq(pDue, due);
        assertEq(pHash, v2.codehash);
        vm.warp(due - 1);
        vm.prank(RECOVERY);
        vm.expectRevert(DepositFactory.NotDue.selector);
        f.acceptImplementation(v2);
        vm.warp(due);
        vm.prank(STRANGER);
        vm.expectRevert(DepositFactory.NotAllowed.selector);
        f.acceptImplementation(v2); // Q6: recovery accepts, nobody else
        vm.expectEmit(true, true, false, false, address(f));
        emit ImplementationListed(v2, 2);
        vm.prank(RECOVERY);
        f.acceptImplementation(v2);
        assertEq(f.versionOf(v2), 2);
        assertEq(f.versions(), 2);
        assertEq(f.latest(), v2);
        assertEq(f.implementationAt(2), v2);
        (pDue,) = f.proposals(v2);
        assertEq(pDue, 0);
        vm.expectRevert(DepositFactory.BadVersion.selector);
        f.implementationAt(3);
        vm.expectRevert(DepositFactory.BadVersion.selector);
        f.implementationAt(0);
    }

    function test_list_eachRefusalOfAProposal() public {
        vm.prank(STRANGER);
        vm.expectRevert(DepositFactory.NotAllowed.selector);
        f.proposeImplementation(v2);
        vm.startPrank(RECOVERY);
        vm.expectRevert(DepositFactory.BadImplementation.selector);
        f.proposeImplementation(address(0xC0DE)); // no code
        address g = f.genesis();
        vm.expectRevert(DepositFactory.AlreadyListed.selector);
        f.proposeImplementation(g);
        f.proposeImplementation(v2);
        vm.expectRevert(DepositFactory.AlreadyPending.selector);
        f.proposeImplementation(v2); // never a silent restart
        vm.stopPrank();
        // another factory's implementation, and an implementation whose module names another factory
        DepositFactory other = new DepositFactory(RECOVERY);
        address foreign = newV2(other);
        DepositAccountRecordV2 foreignModule = new DepositAccountRecordV2(address(other));
        address mixed = address(new DepositAccountV2(address(f), address(foreignModule), address(foreignModule).codehash));
        // a code version not above the list: version 1's code again, made for this factory
        DepositAccountRecord m1 = new DepositAccountRecord(address(f));
        address again = address(new DepositAccount(address(f), address(m1), address(m1).codehash));
        vm.startPrank(RECOVERY);
        vm.expectRevert(DepositFactory.BadImplementation.selector);
        f.proposeImplementation(foreign);
        vm.expectRevert(DepositFactory.BadImplementation.selector);
        f.proposeImplementation(mixed);
        vm.expectRevert(DepositFactory.BadVersion.selector);
        f.proposeImplementation(again);
        vm.stopPrank();
        // the review's P2-1: version 3's main contract over version 1's module (whose forward-only
        // checks would read 1) is refused, so a version can never be downgraded from
        DepositAccountRecord m1f = DepositAccountRecord(DepositAccount(f.genesis()).module());
        address stale = vm.deployCode(
            "DepositAccountV2.sol:DepositAccountV3", abi.encode(address(f), address(m1f), address(m1f).codehash)
        );
        vm.prank(RECOVERY);
        vm.expectRevert(DepositFactory.BadVersion.selector);
        f.proposeImplementation(stale);
    }

    /// Several proposals at once (a chain added later lists its backlog in one 7-day wait), accepted
    /// in version order only.
    function test_list_severalAtOnceAcceptedInOrder() public {
        address v3 = newV3(f);
        vm.startPrank(RECOVERY);
        f.proposeImplementation(v3);
        f.proposeImplementation(v2);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.expectRevert(DepositFactory.BadVersion.selector);
        f.acceptImplementation(v3); // 3 before 2
        f.acceptImplementation(v2);
        f.acceptImplementation(v3);
        vm.stopPrank();
        assertEq(f.versionOf(v3), 3);
        assertEq(f.latest(), v3);
        // once 3 is listed, a proposal of another 3 is refused
        address another3 = newV3(f);
        vm.prank(RECOVERY);
        vm.expectRevert(DepositFactory.BadVersion.selector);
        f.proposeImplementation(another3);
    }

    function test_list_aProposalIsWithdrawnByRecoveryOnly() public {
        vm.prank(RECOVERY);
        f.proposeImplementation(v2);
        vm.prank(STRANGER);
        vm.expectRevert(DepositFactory.NotAllowed.selector);
        f.withdrawImplementation(v2);
        vm.expectEmit(true, false, false, false, address(f));
        emit ImplementationWithdrawn(v2);
        vm.prank(RECOVERY);
        f.withdrawImplementation(v2);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.startPrank(RECOVERY);
        vm.expectRevert(DepositFactory.NothingPending.selector);
        f.acceptImplementation(v2);
        vm.expectRevert(DepositFactory.NothingPending.selector);
        f.withdrawImplementation(v2);
        // proposed again: a new 7 days
        f.proposeImplementation(v2);
        vm.expectRevert(DepositFactory.NotDue.selector);
        f.acceptImplementation(v2);
        vm.stopPrank();
    }

    /// The code accepted is the code proposed.
    function test_list_theCodeHashMustNotChange() public {
        vm.prank(RECOVERY);
        f.proposeImplementation(v2);
        vm.etch(v2, address(newV3(f)).code);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(RECOVERY);
        vm.expectRevert(DepositFactory.BadImplementation.selector);
        f.acceptImplementation(v2);
    }

    /// §A9: a version naming a successor factory that names this one as its predecessor is listed
    /// here; one naming a factory that does not is refused.
    function test_list_aSuccessorsVersion() public {
        SuccessorFactory next = new SuccessorFactory(address(f));
        DepositAccountRecordV2 m = new DepositAccountRecordV2(address(next));
        address succ = address(new DepositAccountV2(address(next), address(m), address(m).codehash));
        SuccessorFactory stranger = new SuccessorFactory(address(0xF00));
        DepositAccountRecordV2 m2 = new DepositAccountRecordV2(address(stranger));
        address notOurs = address(new DepositAccountV2(address(stranger), address(m2), address(m2).codehash));
        DepositAccountRecordV2 m3 = new DepositAccountRecordV2(address(f));
        address split = address(new DepositAccountV2(address(next), address(m3), address(m3).codehash));
        vm.startPrank(RECOVERY);
        vm.expectRevert(DepositFactory.BadImplementation.selector);
        f.proposeImplementation(notOurs);
        vm.expectRevert(DepositFactory.BadImplementation.selector);
        f.proposeImplementation(split); // its module names another factory than the version does
        vm.stopPrank();
        list(f, succ);
        assertEq(f.versionOf(succ), 2);
        assertEq(f.MAX_SUCCESSIONS(), 8);
        assertEq(f.predecessor(), address(0));
    }

    /// Codex's P2: after two successions (this factory, then F1, then F2) a copy deployed here
    /// later still follows its home to version 3, once listed here too; a chain that never reaches
    /// this factory, loops, or is longer than MAX_SUCCESSIONS is refused.
    function test_list_twoSuccessionsAndACopyCatchesUp() public {
        SuccessorFactory f1 = new SuccessorFactory(address(f));
        SuccessorFactory f2 = new SuccessorFactory(address(f1));
        address s2 = newVersion(DepositFactory(address(f1)), "DepositAccountV2.sol:DepositAccountRecordV2", "DepositAccountV2.sol:DepositAccountV2");
        address s3 = newVersion(DepositFactory(address(f2)), "DepositAccountV2.sol:DepositAccountRecordV3", "DepositAccountV2.sol:DepositAccountV3");
        list(f, s2);
        list(f, s3);
        assertEq(f.versionOf(s3), 3);
        vm.chainId(HYPEREVM);
        DepositAccount copy = DepositAccount(f.deploy(BOB, one(wallet(WALLET_A))));
        assertEq(copy.implementation(), f.genesis());
        deliver(copy, upgradeBody(s3, uint64(vm.getBlockTimestamp()))); // the home's current version
        assertEq(copy.implementation(), s3, "version 1 to 3 at once");
        assertEq(copy.CODE_VERSION(), 3);
        // a loop, a chain longer than MAX_SUCCESSIONS, a chain ending elsewhere: refused
        SuccessorFactory loopA = new SuccessorFactory(address(0));
        SuccessorFactory loopB = new SuccessorFactory(address(loopA));
        loopA.setPredecessor(address(loopB));
        address loop = newVersion(DepositFactory(address(loopB)), "DepositAccountV2.sol:DepositAccountRecordV4", "DepositAccountV2.sol:DepositAccountV4");
        address at = address(f2);
        for (uint256 i; i < 7; ++i) at = address(new SuccessorFactory(at)); // f1 … f9: nine below f
        address far = newVersion(DepositFactory(at), "DepositAccountV2.sol:DepositAccountRecordV4", "DepositAccountV2.sol:DepositAccountV4");
        SuccessorFactory orphan = new SuccessorFactory(address(0));
        address elsewhere = newVersion(DepositFactory(address(orphan)), "DepositAccountV2.sol:DepositAccountRecordV4", "DepositAccountV2.sol:DepositAccountV4");
        vm.startPrank(RECOVERY);
        vm.expectRevert(DepositFactory.BadImplementation.selector);
        f.proposeImplementation(loop);
        vm.expectRevert(DepositFactory.BadImplementation.selector);
        f.proposeImplementation(far);
        vm.expectRevert(DepositFactory.BadImplementation.selector);
        f.proposeImplementation(elsewhere);
        vm.stopPrank();
        // eight below f is the limit
        SuccessorFactory f8 = SuccessorFactory(address(f2));
        for (uint256 i; i < 6; ++i) f8 = new SuccessorFactory(address(f8));
        address eighth = newVersion(DepositFactory(address(f8)), "DepositAccountV2.sol:DepositAccountRecordV4", "DepositAccountV2.sol:DepositAccountV4");
        vm.prank(RECOVERY);
        f.proposeImplementation(eighth);
    }

    /// Acceptance seeds the version's check-in clock (§A3): not stopped on arrival, stopped 7 days
    /// after without a check-in; check-ins are per version, and an unlisted number is refused.
    function test_list_checkInsArePerVersion() public {
        list(f, v2);
        assertEq(f.lastCheckIn(2), vm.getBlockTimestamp());
        assertFalse(f.stopped(2));
        assertTrue(f.stopped(1), "the genesis was not checked in for the 7 days of the listing");
        assertTrue(f.stopped(3), "an unlisted number reads stopped");
        uint256[] memory both = new uint256[](2);
        (both[0], both[1]) = (1, 2);
        vm.prank(TRANSFER);
        f.checkIn(both);
        assertFalse(f.stopped(1));
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(TRANSFER);
        f.checkIn(genesisOnly()); // version 2's support ends alone
        assertFalse(f.stopped(1));
        assertTrue(f.stopped(2));
        uint256[] memory bad = new uint256[](1);
        bad[0] = 3;
        vm.prank(TRANSFER);
        vm.expectRevert(DepositFactory.BadVersion.selector);
        f.checkIn(bad);
        bad[0] = 0;
        vm.prank(TRANSFER);
        vm.expectRevert(DepositFactory.BadVersion.selector);
        f.checkIn(bad);
    }

    /// Q0: a deployment after a listing runs the genesis, at the same address.
    function test_list_aDeploymentAfterAListingRunsTheGenesis() public {
        Credential[] memory owners = one(passkey(PASSKEY_B));
        address before = f.addressOf(ALICE, owners);
        list(f, v2);
        assertEq(f.addressOf(ALICE, owners), before, "the address ignores the list");
        vm.prank(STRANGER);
        DepositAccount b = DepositAccount(f.deploy(ALICE, owners));
        assertEq(address(b), before);
        assertEq(b.implementation(), f.genesis());
        assertEq(slotOf(address(b)), f.genesis());
    }

    // ── the upgrade at the home (§3.4) ───────────────────────────────────────────────────────

    function test_home_scheduleAndApply() public {
        list(f, v2);
        uint256 due = vm.getBlockTimestamp() + 24 hours;
        vm.expectEmit(true, false, false, true, address(a));
        emit UpgradeScheduled(v2, 2, due);
        assertEq(scheduleUpgrade(a, PASSKEY_A, v2), due);
        (address impl, uint256 codeVersion, uint256 pDue) = a.pendingUpgrade();
        assertEq(impl, v2);
        assertEq(codeVersion, 2);
        assertEq(pDue, due);
        assertEq(a.recordNonceOf(credOf(PASSKEY_A)), 1, "a record change: the signer's record nonce");
        uint64 recordVersion = a.version();

        vm.warp(due - 1);
        vm.prank(STRANGER);
        vm.expectRevert(DepositAccountState.NotDue.selector);
        rec(a).applyUpgrade();
        // the old version runs unchanged meanwhile
        assertEq(a.implementation(), f.genesis());

        vm.warp(due);
        vm.expectEmit(true, false, false, false, address(a));
        emit Upgraded(v2);
        vm.prank(STRANGER);
        rec(a).applyUpgrade();
        assertEq(a.implementation(), v2);
        assertEq(slotOf(address(a)), v2);
        assertEq(a.CODE_VERSION(), 2);
        assertEq(a.version(), recordVersion, "an upgrade is not a record change");
        (impl,, pDue) = a.pendingUpgrade();
        assertEq(impl, address(0));
        assertEq(pDue, 0);
        // the new field reads zero, the new function works
        assertEq(DepositAccountV2(address(a)).extra(), 0);
        DepositAccountV2(address(a)).bump();
        assertEq(DepositAccountV2(address(a)).extra(), 1);
        vm.prank(STRANGER);
        vm.expectRevert(DepositAccountState.NothingPending.selector);
        rec(a).applyUpgrade();
    }

    function test_home_eachRefusalOfASchedule() public {
        list(f, v2);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        uint256 nonce = a.recordNonceOf(credOf(WALLET_A));
        bytes32 d = typed(a, abi.encode(a.SCHEDULE_UPGRADE_TYPEHASH(), v2, nonce, deadline));
        DepositAccountRecord r = rec(a);
        // a bad signature, a nonce, a deadline
        vm.expectRevert(DepositAccountState.BadSignature.selector);
        r.scheduleUpgrade(v2, nonce, deadline, sign(WALLET_B, d));
        bytes32 d1 = typed(a, abi.encode(a.SCHEDULE_UPGRADE_TYPEHASH(), v2, nonce + 1, deadline));
        vm.expectRevert(DepositAccountState.BadNonce.selector);
        r.scheduleUpgrade(v2, nonce + 1, deadline, sign(WALLET_A, d1));
        vm.warp(deadline + 1);
        vm.expectRevert(DepositAccountState.Expired.selector);
        r.scheduleUpgrade(v2, nonce, deadline, sign(WALLET_A, d));
        // unlisted, and not higher (the genesis itself)
        address v3 = newV3(f);
        deadline = vm.getBlockTimestamp() + 1 hours;
        d = typed(a, abi.encode(a.SCHEDULE_UPGRADE_TYPEHASH(), v3, nonce, deadline));
        vm.expectRevert(DepositAccountState.BadImplementation.selector);
        r.scheduleUpgrade(v3, nonce, deadline, sign(WALLET_A, d));
        address g = f.genesis();
        d = typed(a, abi.encode(a.SCHEDULE_UPGRADE_TYPEHASH(), g, nonce, deadline));
        vm.expectRevert(DepositAccountState.BadImplementation.selector);
        r.scheduleUpgrade(g, nonce, deadline, sign(WALLET_A, d));
        // not at the home
        vm.chainId(HYPEREVM);
        d = typed(a, abi.encode(a.SCHEDULE_UPGRADE_TYPEHASH(), v2, nonce, deadline));
        vm.expectRevert(DepositAccountState.NotHome.selector);
        r.scheduleUpgrade(v2, nonce, deadline, sign(WALLET_A, d));
    }

    /// Q13: one pending upgrade, never replaced. The owner cancels, then signs again.
    function test_home_noReplacementCancelThenScheduleAgain() public {
        list(f, v2);
        address v3 = newV3(f);
        list(f, v3);
        uint256 due = scheduleUpgrade(a, WALLET_A, v2);
        (uint256 nonce, uint256 deadline, bytes memory sig) = scheduleUpgradeSig(a, PASSKEY_A, v3);
        DepositAccountRecord r = rec(a);
        vm.expectRevert(DepositAccountState.AlreadyPending.selector);
        r.scheduleUpgrade(v3, nonce, deadline, sig);
        cancelUpgrade(a, PASSKEY_A, v2, due);
        assertEq(scheduleUpgrade(a, PASSKEY_A, v3), vm.getBlockTimestamp() + 24 hours);
        (address impl,,) = a.pendingUpgrade();
        assertEq(impl, v3);
    }

    /// Any credential in effect cancels, the scheduler included; and with one credential, that one.
    /// The cancel names the upgrade and its due time.
    function test_home_cancelByEachCredential() public {
        list(f, v2);
        uint256 due = scheduleUpgrade(a, WALLET_A, v2);
        DepositAccountRecord r = rec(a);
        (uint256 dl, bytes memory sig) = cancelUpgradeSig(a, PASSKEY_A, v2, due + 1);
        vm.expectRevert(DepositAccountState.NothingPending.selector);
        r.cancelUpgrade(v2, due + 1, dl, sig);
        address v3 = newV3(f);
        (dl, sig) = cancelUpgradeSig(a, PASSKEY_A, v3, due);
        vm.expectRevert(DepositAccountState.NothingPending.selector);
        r.cancelUpgrade(v3, due, dl, sig);
        (dl, sig) = cancelUpgradeSig(a, WALLET_B, v2, due);
        vm.expectRevert(DepositAccountState.BadSignature.selector);
        r.cancelUpgrade(v2, due, dl, sig);
        vm.expectEmit(true, false, false, true, address(a));
        emit UpgradeCancelled(v2, due);
        cancelUpgrade(a, PASSKEY_A, v2, due);
        // the scheduler itself
        due = scheduleUpgrade(a, WALLET_A, v2);
        cancelUpgrade(a, WALLET_A, v2, due);
        // one credential
        DepositAccount solo = DepositAccount(f.deploy(BOB, one(wallet(WALLET_B))));
        due = scheduleUpgrade(solo, WALLET_B, v2);
        cancelUpgrade(solo, WALLET_B, v2, due);
        (address impl,,) = solo.pendingUpgrade();
        assertEq(impl, address(0));
        vm.warp(due);
        vm.expectRevert(DepositAccountState.NothingPending.selector);
        rec(solo).applyUpgrade();
    }

    /// Q9: a cancel signed and submitted after the due time succeeds while nothing applied it.
    function test_home_aLateCancelBeatsAnApplyNobodyMade() public {
        list(f, v2);
        uint256 due = scheduleUpgrade(a, WALLET_A, v2);
        vm.warp(due + 3 days);
        cancelUpgrade(a, PASSKEY_A, v2, due);
        vm.prank(STRANGER);
        vm.expectRevert(DepositAccountState.NothingPending.selector);
        rec(a).applyUpgrade();
        assertEq(a.implementation(), f.genesis());
    }

    /// A schedule dies with its signer: a removal of the scheduler proposed (pending at the apply) or
    /// landed (settled by the apply) clears it; a removal of another credential does not.
    function test_home_theSchedulersRemovalClearsItsSchedule() public {
        list(f, v2);
        uint256 snap = vm.snapshotState();
        // pending at the apply
        uint256 due = scheduleUpgrade(a, WALLET_A, v2);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        proposeRemoval(a, PASSKEY_A, wallet(WALLET_A));
        vm.warp(due);
        vm.expectEmit(true, false, false, true, address(a));
        emit UpgradeCancelled(v2, due);
        vm.prank(STRANGER);
        rec(a).applyUpgrade();
        assertEq(a.implementation(), f.genesis(), "not applied");
        (address impl,,) = a.pendingUpgrade();
        assertEq(impl, address(0), "cleared");
        // landed by then: settled first, then refused
        vm.revertToState(snap);
        proposeRemoval(a, PASSKEY_A, wallet(WALLET_A));
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        // the thief's own schedule while its removal is pending is refused outright
        (uint256 nonce, uint256 deadline, bytes memory sig) = scheduleUpgradeSig(a, WALLET_A, v2);
        DepositAccountRecord r = rec(a);
        vm.expectRevert(DepositAccountState.RemovalPending.selector);
        r.scheduleUpgrade(v2, nonce, deadline, sig);
        vm.revertToState(snap);
        due = scheduleUpgrade(a, WALLET_A, v2);
        proposeRemoval(a, PASSKEY_A, wallet(WALLET_A)); // lands at the same second as the upgrade's due
        vm.warp(due);
        vm.prank(STRANGER);
        rec(a).applyUpgrade();
        assertEq(a.implementation(), f.genesis(), "the scheduler removed by the settle: not applied");
        assertFalse(a.isCredential(wallet(WALLET_A)));
        // another credential's removal does not clear it
        vm.revertToState(snap);
        addNow(a, WALLET_A, wallet(WALLET_B));
        due = scheduleUpgrade(a, WALLET_A, v2);
        proposeRemoval(a, WALLET_A, wallet(WALLET_B));
        assertTrue(a.removalPendingOf(a.credentialId(wallet(WALLET_B))));
        assertFalse(a.removalPendingOf(a.credentialId(wallet(WALLET_A))));
        vm.warp(due);
        vm.prank(STRANGER);
        rec(a).applyUpgrade();
        assertEq(a.implementation(), v2);
    }

    /// Settle before switch: a change due by the apply lands under the code that accepted it, its
    /// event before ERC-1967's.
    function test_home_settleBeforeSwitch() public {
        list(f, v2);
        setWithdrawalNow(a, WALLET_A, DEST); // the first address, in effect at once
        uint256 due = scheduleUpgrade(a, WALLET_A, v2);
        setWithdrawal(a, PASSKEY_A, DEST2); // due at the same second as the upgrade
        uint64 v = a.version();
        vm.warp(due);
        vm.expectEmit(true, true, false, true, address(a));
        emit WithdrawalAddressSet(DEST, DEST2, v + 1);
        vm.expectEmit(true, false, false, false, address(a));
        emit Upgraded(v2);
        vm.prank(STRANGER);
        rec(a).applyUpgrade();
        assertEq(a.withdrawalAddress(), DEST2);
        (address next, uint256 pendingDue) = a.pendingWithdrawalAddress();
        assertEq(next, address(0));
        assertEq(pendingDue, 0);
    }

    /// Codex round 1: a token or recipient callback during a withdrawal cannot switch the code.
    function test_home_noApplyUnderTheMoneyLock() public {
        list(f, v2);
        ApplyingRecipient r = new ApplyingRecipient();
        r.set(address(a));
        setWithdrawalNow(a, WALLET_A, address(r));
        uint256 due = scheduleUpgrade(a, WALLET_A, v2);
        vm.warp(due);
        vm.deal(address(a), 1 ether);
        vm.prank(TRANSFER);
        a.withdraw(address(0), 1 ether);
        assertTrue(r.tried());
        assertEq(r.err(), abi.encodeWithSelector(DepositAccountState.Reentered.selector));
        assertEq(a.implementation(), f.genesis());
        vm.prank(STRANGER);
        rec(a).applyUpgrade();
        assertEq(a.implementation(), v2);
    }

    /// I5: every piece of in-flight state survives the switch with a value in it, and what is pending
    /// lands under version 2 by the same rule. The fixed slots are compared raw; the mappings by view.
    function test_home_inFlightStateSurvives() public {
        list(f, v2);
        // a trust in effect with an applied grant, a trust pending with a grant, a dispatched grant
        FixtureVaultFactory vf = new FixtureVaultFactory();
        FixtureVaultFactory pendingVf = new FixtureVaultFactory();
        setWithdrawalNow(a, WALLET_A, DEST);
        authorise(a, WALLET_A, address(vf), 3, bytes32("s1"), bytes32("c1"), 100e6);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        a.applyAuthorisation(1);
        uint256 pendingGrant = authorise(a, PASSKEY_A, address(pendingVf), 3, bytes32("s2"), bytes32("c2"), 7e6);
        uint256 remoteGrant = authorise(a, WALLET_A, address(vf), 19, bytes32("s3"), bytes32("c3"), 9e6);
        // the burn budget, from a fee-paying burn
        vm.etch(USDC, address(new MockToken()).code);
        vm.etch(TM, address(new MockTokenMessenger()).code);
        MockTokenMessenger(TM).setMinFee(true, 1_000); // 1 bp
        MockToken(USDC).mint(address(a), 10_000e6);
        vm.prank(TRANSFER);
        a.convertBurn(1_000e6, 19);
        // a revoked transfer key and local nonces, then the upgrade scheduled
        (uint256 n, uint256 dl, bytes memory sig) = revokeSig(a, PASSKEY_A, true);
        a.revokeTransfer(n, dl, sig);
        uint256 due = scheduleUpgrade(a, WALLET_A, v2);
        // then, within the 24 hours, an addition, a removal and an address change, all pending at the switch
        vm.warp(vm.getBlockTimestamp() + 23 hours);
        addCredential(a, WALLET_A, wallet(WALLET_B));
        setWithdrawal(a, PASSKEY_A, DEST2);
        DepositAccount solo = a; // the removal: of PASSKEY_A, by WALLET_A
        proposeRemoval(solo, WALLET_A, passkey(PASSKEY_A));
        vm.warp(due);

        bytes32[19] memory fixedBefore;
        for (uint256 i; i < 19; ++i) fixedBefore[i] = vm.load(address(a), bytes32(i));
        Credential[] memory credsBefore = a.credentials();
        uint256 addDue = a.additionDue(wallet(WALLET_B));
        uint256 removalDue = a.removalDue(passkey(PASSKEY_A));
        (address nextW, uint256 nextDue) = a.pendingWithdrawalAddress();
        uint256 recordNonceA = a.recordNonceOf(credOf(WALLET_A));
        uint256 recordNonceP = a.recordNonceOf(credOf(PASSKEY_A));
        uint256 localNonceA = a.localNonceOf(credOf(WALLET_A));
        uint256 localNonceP = a.localNonceOf(credOf(PASSKEY_A));
        (uint256 trustDue, uint256 trustEpoch) = a.trustOf(address(pendingVf), 3);
        uint64 v = a.version();

        vm.prank(STRANGER);
        rec(a).applyUpgrade();
        assertEq(a.implementation(), v2);

        for (uint256 i; i < 19; ++i) assertEq(vm.load(address(a), bytes32(i)), fixedBefore[i], "a fixed slot moved");
        assertEq(abi.encode(a.credentials()), abi.encode(credsBefore));
        assertEq(a.additionDue(wallet(WALLET_B)), addDue);
        assertEq(a.removalDue(passkey(PASSKEY_A)), removalDue);
        (address w2, uint256 d2) = a.pendingWithdrawalAddress();
        assertEq(w2, nextW);
        assertEq(d2, nextDue);
        assertEq(a.recordNonceOf(credOf(WALLET_A)), recordNonceA);
        assertEq(a.recordNonceOf(credOf(PASSKEY_A)), recordNonceP);
        assertEq(a.localNonceOf(credOf(WALLET_A)), localNonceA);
        assertEq(a.localNonceOf(credOf(PASSKEY_A)), localNonceP);
        assertEq(a.allowanceOf(address(vf), bytes32("s1"), bytes32("c1")), 100e6);
        (uint256 td, uint256 te) = a.trustOf(address(pendingVf), 3);
        assertEq(td, trustDue);
        assertEq(te, trustEpoch);
        assertEq(a.grant(pendingGrant).allowance, 7e6);
        assertEq(a.grant(remoteGrant).domain, 19);
        assertEq(a.authorisationCount(), 3);
        assertTrue(a.transferRevoked());
        assertEq(a.version(), v);
        assertTrue(a.removalPendingOf(a.credentialId(passkey(PASSKEY_A))));
        assertEq(DepositAccountV2(address(a)).extra(), 0);

        // the 24 hours of changes accepted under version 1 are served under version 2 exactly
        vm.warp(trustDue);
        a.applyAuthorisation(pendingGrant);
        assertEq(a.allowanceOf(address(pendingVf), bytes32("s2"), bytes32("c2")), 7e6);
        a.dispatchAuthorisation(remoteGrant);
        vm.warp(addDue);
        assertTrue(a.isCredential(wallet(WALLET_B)));
        assertFalse(a.isCredential(passkey(PASSKEY_A)));
        assertEq(a.withdrawalAddress(), DEST2);
        rec(a).publish(19); // settles under version 2
        assertEq(a.version(), v + 3);
        assertFalse(a.removalPendingOf(a.credentialId(passkey(PASSKEY_A))));
    }

    // ── the copies (§3.5) ────────────────────────────────────────────────────────────────────

    function test_copy_publishUpgradeAtTheHome() public {
        list(f, v2);
        upgradeNow(a, WALLET_A, v2);
        vm.expectEmit(true, true, false, false, address(a));
        emit UpgradePublished(19, v2);
        vm.prank(STRANGER);
        rec(a).publishUpgrade(19);
        assertEq(mt.lastDomain(), 19);
        assertEq(mt.lastRecipient(), self(a));
        assertEq(mt.lastCaller(), bytes32(0));
        assertEq(mt.lastThreshold(), 2000);
        assertEq(mt.body(), upgradeBody(v2, uint64(vm.getBlockTimestamp())));
        vm.expectRevert(DepositAccountState.BadDomain.selector);
        rec(a).publishUpgrade(3);
        // a version-1 home publishes its genesis (a copy ignores it: not higher)
        DepositAccount b = DepositAccount(f.deploy(ALICE, one(wallet(WALLET_B))));
        rec(b).publishUpgrade(0);
        assertEq(mt.body(), upgradeBody(f.genesis(), uint64(vm.getBlockTimestamp())));
        vm.chainId(HYPEREVM);
        vm.expectRevert(DepositAccountState.NotHome.selector);
        rec(a).publishUpgrade(0);
    }

    /// A copy on HyperEVM: the home's applied version followed, forward only; a stale or replayed
    /// message ignored; an unlisted one reverted (relayable), then applied once listed there.
    function test_copy_followsTheHome() public {
        vm.chainId(HYPEREVM);
        vm.warp(vm.getBlockTimestamp() + 10 days);
        DepositAccount copy = DepositAccount(f.deploy(BOB, one(wallet(WALLET_A))));
        uint64 t0 = uint64(vm.getBlockTimestamp());
        // unlisted on this chain: reverts, the message is not consumed
        bytes memory body = upgradeBody(v2, t0);
        vm.prank(MT);
        vm.expectRevert(DepositAccountState.BadImplementation.selector);
        rec(copy).handleReceiveFinalizedMessage(3, self(copy), 2000, body);
        // listed: the same message, relayed again within its 3 days, applies
        uint256 snap = vm.snapshotState();
        vm.warp(t0 - 5 days); // proposed 5 days before the message
        vm.prank(RECOVERY);
        f.proposeImplementation(v2);
        vm.warp(t0 + 2 days);
        vm.prank(RECOVERY);
        f.acceptImplementation(v2);
        vm.expectEmit(true, false, false, false, address(copy));
        emit Upgraded(v2);
        deliver(copy, body);
        assertEq(copy.implementation(), v2, "the message that reverted, relayed again");
        vm.revertToState(snap);
        // listed only 7 days after the message: stale by then, consumed and ignored
        vm.prank(RECOVERY);
        f.proposeImplementation(v2);
        vm.warp(t0 + 2 days);
        vm.prank(RECOVERY);
        vm.expectRevert(DepositFactory.NotDue.selector);
        f.acceptImplementation(v2);
        vm.warp(t0 + 7 days);
        vm.prank(RECOVERY);
        f.acceptImplementation(v2);
        vm.expectEmit(true, false, false, true, address(copy));
        emit UpgradeIgnored(v2, t0);
        deliver(copy, body); // older than UPGRADE_TTL: consumed, ignored; the home publishes again
        assertEq(copy.implementation(), f.genesis());
        uint64 t1 = uint64(vm.getBlockTimestamp());
        body = upgradeBody(v2, t1);
        vm.expectEmit(true, false, false, false, address(copy));
        emit Upgraded(v2);
        deliver(copy, body);
        assertEq(copy.implementation(), v2);
        assertEq(copy.CODE_VERSION(), 2);
        // a replay is ignored, and so is any message not higher
        vm.expectEmit(true, false, false, true, address(copy));
        emit UpgradeIgnored(v2, t1);
        deliver(copy, body);
        deliver(copy, upgradeBody(f.genesis(), t1 + 1));
        assertEq(copy.implementation(), v2, "never backwards");
        // version 3, a later message: applies
        address v3 = newV3(f);
        list(f, v3);
        deliver(copy, upgradeBody(v3, uint64(vm.getBlockTimestamp())));
        assertEq(copy.implementation(), v3);
    }

    /// Codex's P3: a message published after the copy's deployment but before its last applied
    /// upgrade, within its 3 days and higher, is ignored for its order alone.
    function test_copy_ignoresAMessageOlderThanItsLastUpgrade() public {
        address v3 = newV3(f);
        list(f, v2);
        list(f, v3);
        vm.chainId(HYPEREVM);
        DepositAccount copy = DepositAccount(f.deploy(BOB, one(wallet(WALLET_A))));
        uint64 t = uint64(vm.getBlockTimestamp());
        vm.warp(t + 10);
        deliver(copy, upgradeBody(v2, t + 10));
        vm.expectEmit(true, false, false, true, address(copy));
        emit UpgradeIgnored(v3, t + 5);
        deliver(copy, upgradeBody(v3, t + 5));
        assertEq(copy.implementation(), v2, "an older message, though higher and fresh");
        deliver(copy, upgradeBody(v3, t + 10));
        assertEq(copy.implementation(), v3);
    }

    /// The review's P2-3: the home's version-2 message and its version-3 message of the same second
    /// (one block: published, then upgraded and published again) both count, in either order.
    function test_copy_twoMessagesOfTheSameSecond() public {
        address v3 = newV3(f);
        list(f, v2);
        list(f, v3);
        vm.chainId(HYPEREVM);
        DepositAccount copy = DepositAccount(f.deploy(BOB, one(wallet(WALLET_A))));
        uint64 t = uint64(vm.getBlockTimestamp());
        deliver(copy, upgradeBody(v2, t));
        deliver(copy, upgradeBody(v3, t));
        assertEq(copy.implementation(), v3);
        deliver(copy, upgradeBody(v2, t)); // the earlier one again: not higher
        assertEq(copy.implementation(), v3);
    }

    /// Codex round 1: a message kept from before the copy was deployed never installs anything.
    function test_copy_ignoresAMessageOlderThanItself() public {
        list(f, v2);
        vm.chainId(HYPEREVM);
        uint64 early = uint64(vm.getBlockTimestamp());
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        DepositAccount copy = DepositAccount(f.deploy(BOB, one(wallet(WALLET_A))));
        vm.expectEmit(true, false, false, true, address(copy));
        emit UpgradeIgnored(v2, early);
        deliver(copy, upgradeBody(v2, early));
        assertEq(copy.implementation(), f.genesis());
        deliver(copy, upgradeBody(v2, uint64(vm.getBlockTimestamp())));
        assertEq(copy.implementation(), v2);
    }

    /// The handler's checks stay: the transmitter, the home's domain and address, finalized, a copy.
    function test_copy_theHandlersChecksHold() public {
        list(f, v2);
        vm.chainId(HYPEREVM);
        DepositAccount copy = DepositAccount(f.deploy(BOB, one(wallet(WALLET_A))));
        bytes memory body = upgradeBody(v2, uint64(vm.getBlockTimestamp()));
        DepositAccountRecord r = rec(copy);
        vm.expectRevert(DepositAccountState.NotTransmitter.selector);
        r.handleReceiveFinalizedMessage(3, self(copy), 2000, body);
        vm.startPrank(MT);
        vm.expectRevert(DepositAccountState.NotHomeMessage.selector);
        r.handleReceiveFinalizedMessage(19, self(copy), 2000, body);
        vm.expectRevert(DepositAccountState.NotHomeMessage.selector);
        r.handleReceiveFinalizedMessage(3, bytes32(uint256(0xBAD)), 2000, body);
        vm.expectRevert(DepositAccountState.NotFinalized.selector);
        r.handleReceiveFinalizedMessage(3, self(copy), 1000, body);
        vm.expectRevert(DepositAccountState.NotFinalized.selector);
        r.handleReceiveUnfinalizedMessage(3, self(copy), 1000, body);
        vm.stopPrank();
        vm.chainId(ARBITRUM);
        DepositAccountRecord home = rec(a);
        vm.prank(MT);
        vm.expectRevert(DepositAccountState.NotCopy.selector);
        home.handleReceiveFinalizedMessage(3, self(a), 2000, body);
    }

    /// The copy's handler refuses under the money lock (§3.4): a withdrawal's recipient callback
    /// cannot switch a copy's code either.
    function test_copy_noFollowUnderTheMoneyLock() public {
        list(f, v2);
        vm.chainId(HYPEREVM);
        DepositAccount copy = DepositAccount(f.deploy(BOB, one(wallet(WALLET_A))));
        vm.etch(MT, address(new RelayingTransmitter()).code);
        RelayingTransmitter relay = RelayingTransmitter(payable(MT));
        relay.set(address(copy), upgradeBody(v2, uint64(vm.getBlockTimestamp())));
        // the copy synced, its withdrawal address the transmitter itself (so its callback is the
        // transmitter's own call)
        bytes memory record =
            abi.encode(copy.RECORD_TAG(), uint64(0), uint64(vm.getBlockTimestamp()), MT, one(wallet(WALLET_A)));
        vm.prank(MT);
        rec(copy).handleReceiveFinalizedMessage(3, self(copy), 2000, record);
        vm.deal(address(copy), 1 ether);
        vm.prank(TRANSFER);
        copy.withdraw(address(0), 1 ether);
        assertEq(relay.err(), abi.encodeWithSelector(DepositAccountState.Reentered.selector));
        assertEq(copy.implementation(), f.genesis());
    }

    /// §3.6: a version-2 home's record is read by a version-1 copy, and a copy ahead of its home (on
    /// version 3, its home still on 2) still takes the home's record.
    function test_copy_recordsAcrossVersions() public {
        list(f, v2);
        address v3 = newV3(f);
        list(f, v3);
        DepositAccount b = DepositAccount(f.deploy(BOB, one(wallet(WALLET_A))));
        uint256 genesisState = vm.snapshotState();
        // at the home: a second credential, version 2, an address, the record published
        addNow(b, WALLET_A, passkey(PASSKEY_A));
        upgradeNow(b, WALLET_A, v2);
        setWithdrawalNow(b, WALLET_A, DEST);
        rec(b).publish(19);
        bytes memory record = mt.body();
        // the same address on HyperEVM, as just deployed there (version 1)
        vm.revertToState(genesisState);
        vm.chainId(HYPEREVM);
        uint256 copyState = vm.snapshotState();
        deliver(b, record);
        assertEq(b.CODE_VERSION(), 1);
        assertTrue(b.synced());
        assertEq(b.withdrawalAddress(), DEST);
        assertTrue(b.isCredential(passkey(PASSKEY_A)));
        // a copy ahead of its home (on version 3, the home on 2) reads it too
        vm.revertToState(copyState);
        deliver(b, upgradeBody(v3, uint64(vm.getBlockTimestamp())));
        assertEq(b.CODE_VERSION(), 3);
        deliver(b, record);
        assertEq(b.withdrawalAddress(), DEST);
        assertTrue(b.isCredential(passkey(PASSKEY_A)));
    }

    // ── unusable directly (§3.3) ─────────────────────────────────────────────────────────────

    function test_direct_theImplementationIsNoAccount() public {
        DepositAccount g = DepositAccount(f.genesis());
        DepositAccountRecord gr = DepositAccountRecord(address(g));
        assertEq(g.implementation(), address(0));
        vm.prank(address(f));
        vm.expectRevert(DepositAccountState.AlreadyInitialised.selector);
        g.initialize(one(wallet(WALLET_A)));
        uint256 deadline = vm.getBlockTimestamp() + 1;
        bytes memory sig = sign(WALLET_A, typed(g, abi.encode(g.SCHEDULE_UPGRADE_TYPEHASH(), v2, 0, deadline)));
        vm.expectRevert(DepositAccountState.BadSignature.selector);
        gr.scheduleUpgrade(v2, 0, deadline, sig);
        vm.expectRevert(DepositAccountState.NotInitialised.selector);
        gr.applyUpgrade();
        vm.expectRevert(DepositAccountState.NotInitialised.selector);
        gr.publishUpgrade(19);
        vm.expectRevert(DepositAccountState.NotInitialised.selector);
        gr.publish(19);
        vm.prank(MT);
        vm.expectRevert(DepositAccountState.NotInitialised.selector);
        gr.handleReceiveFinalizedMessage(3, bytes32(uint256(uint160(address(g)))), 2000, upgradeBody(v2, 1));
        vm.expectRevert(DepositAccountState.BadSignature.selector);
        gr.setWithdrawalAddress(DEST, 0, deadline, sig);
        Credential memory c = wallet(WALLET_B);
        vm.expectRevert(DepositAccountState.BadSignature.selector);
        gr.addCredential(c, 0, deadline, sig);
        vm.expectRevert(DepositAccountState.BadSignature.selector);
        gr.cancelAddition(c, 1, deadline, sig);
        vm.expectRevert(DepositAccountState.BadSignature.selector);
        gr.proposeRemoval(c, 0, deadline, sig);
        vm.expectRevert(DepositAccountState.BadSignature.selector);
        gr.cancelRemoval(c, 1, deadline, sig);
        vm.expectRevert(DepositAccountState.BadSignature.selector);
        gr.cancelWithdrawalAddress(DEST, 1, deadline, sig);
        vm.expectRevert(DepositAccountState.BadSignature.selector);
        gr.cancelUpgrade(v2, 1, deadline, sig);
        vm.expectRevert(DepositAccountState.BadSignature.selector);
        g.revokeTransfer(0, deadline, sig);
        vm.expectRevert(DepositAccountState.BadSignature.selector);
        g.allowTransfer(0, deadline, sig);
        vm.expectRevert(DepositAccountState.BadSignature.selector);
        g.cancelTrust(address(0xF), 3, 1, deadline, sig);
        StrategyGrant memory sg = StrategyGrant(address(0xF), 3, bytes32("s"), bytes32("c"), 1, 0, deadline);
        vm.expectRevert(DepositAccountState.BadSignature.selector);
        g.authoriseStrategy(sg, sig);
        Withdrawal memory w = Withdrawal(address(0), 1, DEST, 0, address(0), 0, deadline);
        vm.expectRevert(DepositAccountState.BadSignature.selector);
        g.withdrawSigned(w, 0, sig);
        vm.expectRevert(DepositAccountState.NoGrant.selector);
        g.applyAuthorisation(1);
        vm.expectRevert(DepositAccountState.NoGrant.selector);
        g.dispatchAuthorisation(1);
        vm.prank(TRANSFER);
        vm.expectRevert(DepositAccountState.NoWithdrawalAddress.selector);
        g.withdraw(address(0), 1);
        vm.prank(TRANSFER);
        vm.expectRevert(DepositAccountState.NoWithdrawalAddress.selector);
        g.fund(address(0xF), address(0xF), 1);
        vm.expectRevert(DepositAccountState.NotAllowed.selector);
        g.convertSwap(1, 0); // the transfer key only; there, its own empty balance
        vm.expectRevert(DepositAccountState.NotAllowed.selector);
        g.convertBurn(1, 0);
        vm.expectRevert(DepositAccountState.NotAllowed.selector);
        g.uniswapV3SwapCallback(1, 1, "");
        assertEq(slotOf(address(g)), address(0));
        assertEq(g.credentials().length, 0, "never a credential");
    }

    /// The module refuses every call in its own storage (`delegated`).
    function test_direct_theModuleRefusesADirectCall() public {
        DepositAccountRecord m = DepositAccountRecord(DepositAccount(f.genesis()).module());
        Credential memory c = wallet(WALLET_A);
        vm.startPrank(MT);
        vm.expectRevert(DepositAccountState.NotAllowed.selector);
        m.addCredential(c, 0, 1, "");
        vm.expectRevert(DepositAccountState.NotAllowed.selector);
        m.cancelAddition(c, 1, 1, "");
        vm.expectRevert(DepositAccountState.NotAllowed.selector);
        m.proposeRemoval(c, 0, 1, "");
        vm.expectRevert(DepositAccountState.NotAllowed.selector);
        m.cancelRemoval(c, 1, 1, "");
        vm.expectRevert(DepositAccountState.NotAllowed.selector);
        m.setWithdrawalAddress(DEST, 0, 1, "");
        vm.expectRevert(DepositAccountState.NotAllowed.selector);
        m.cancelWithdrawalAddress(DEST, 1, 1, "");
        vm.expectRevert(DepositAccountState.NotAllowed.selector);
        m.scheduleUpgrade(v2, 0, 1, "");
        vm.expectRevert(DepositAccountState.NotAllowed.selector);
        m.cancelUpgrade(v2, 1, 1, "");
        vm.expectRevert(DepositAccountState.NotAllowed.selector);
        m.applyUpgrade();
        vm.expectRevert(DepositAccountState.NotAllowed.selector);
        m.publishUpgrade(19);
        vm.expectRevert(DepositAccountState.NotAllowed.selector);
        m.publish(19);
        vm.expectRevert(DepositAccountState.NotAllowed.selector);
        m.handleReceiveFinalizedMessage(3, bytes32(uint256(uint160(address(m)))), 2000, "");
        vm.stopPrank();
        assertEq(slotOf(address(m)), address(0));
    }

    /// The account's own selectors only: an unknown one falls through to the module, whose dispatcher
    /// refuses it; and no coin is taken.
    function test_direct_unknownSelectorsAndCoinRevert() public {
        (bool ok,) = address(a).call(abi.encodeWithSignature("nothingHere()"));
        assertFalse(ok);
        vm.deal(address(this), 1 ether);
        (ok,) = address(a).call{value: 1}("");
        assertFalse(ok, "no payable entry in version 1");
        (ok,) = address(a).call{value: 1}(abi.encodeWithSignature("publish(uint32)", uint32(19)));
        assertFalse(ok, "the module's functions take no coin either");
    }

    /// A version's main contract checks its module's code hash.
    function test_direct_theModuleIsPinnedByItsCodeHash() public {
        DepositAccountRecord m = new DepositAccountRecord(address(f));
        vm.expectRevert(DepositAccountState.BadModule.selector);
        new DepositAccount(address(f), address(m), bytes32(uint256(1)));
        vm.expectRevert(DepositAccountState.BadModule.selector);
        new DepositAccount(address(f), address(0xC0DE), keccak256(""));
        vm.expectRevert(DepositAccountState.BadModule.selector);
        new DepositAccount(address(f), address(m), bytes32(0));
    }
}
