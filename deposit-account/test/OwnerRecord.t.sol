// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {Credential, DepositAccount} from "../src/DepositAccount.sol";
import {DepositFactory} from "../src/DepositFactory.sol";
import {ContractWallet, Helpers, MockTransmitter} from "./Helpers.sol";

/*
 * The owner (spec §7): wallet and passkey signatures, the home's record changes and their delays, the
 * copies kept by the home's own Circle message. No fork: Circle's transmitter is a mock etched at its
 * address; the P-256 verification runs OpenZeppelin's Solidity fallback (no precompile here).
 */
contract OwnerRecordTest is Helpers {
    DepositFactory f;
    DepositAccount a;
    MockTransmitter mt;
    address constant MT = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;
    uint256 constant ARBITRUM = 42161;
    uint256 constant HYPEREVM = 999;
    /// The account as it is on a chain where only its genesis exists: one credential, version 0
    /// (decision 76), the copy the tests of §7.3 start from.
    uint256 copyGenesis;

    function setUp() public {
        vm.chainId(ARBITRUM);
        f = deployFactory();
        vm.prank(RECOVERY);
        f.setTransferKey(TRANSFER);
        a = DepositAccount(f.deploy(ALICE, one(wallet(WALLET_A))));
        vm.etch(MT, address(new MockTransmitter()).code);
        mt = MockTransmitter(MT);
        uint256 snap = vm.snapshotState();
        copyGenesis = snap;
        // the owner's second credential, at the home: version 1 and WALLET_A's record nonce 1 below
        addNow(a, WALLET_A, passkey(PASSKEY_A));
    }

    /// Back to the genesis state, on another chain: a copy no record has reached yet.
    function toCopyAtGenesis() internal {
        vm.revertToState(copyGenesis);
        vm.chainId(HYPEREVM);
    }

    function self() internal view returns (bytes32) {
        return bytes32(uint256(uint160(address(a))));
    }

    // ── signatures ───────────────────────────────────────────────────────────────────────────

    function test_aWalletSignatureVerifies() public view {
        bytes32 d = keccak256("anything the owner signs");
        assertTrue(a.checkOwnerSignature(d, signWallet(WALLET_A, d)));
        assertFalse(a.checkOwnerSignature(d, signWallet(WALLET_B, d)), "not a credential");
        assertFalse(a.checkOwnerSignature(keccak256("another"), signWallet(WALLET_A, d)), "another digest");
    }

    /// A real WebAuthn assertion (authenticatorData, clientDataJSON with the digest as its challenge)
    /// from a P-256 test key, verified by OpenZeppelin's WebAuthn.
    function test_aPasskeyAssertionVerifies() public {
        bytes32 d = keccak256("anything the owner signs");
        bytes memory sig = signPasskey(PASSKEY_A, d);
        uint256 g = gasleft();
        assertTrue(a.checkOwnerSignature(d, sig));
        emit log_named_uint("passkey verification gas, no precompile (local EVM)", g - gasleft());
        assertFalse(a.checkOwnerSignature(keccak256("another"), sig), "the challenge is the digest");
        assertFalse(a.checkOwnerSignature(d, signPasskey(PASSKEY_B, d)), "not a credential");
        assertFalse(a.checkOwnerSignature(d, signPasskeyFlags(PASSKEY_A, d, 0x01)), "user verification required");
        assertFalse(a.checkOwnerSignature(d, signPasskeyFlags(PASSKEY_A, d, 0x04)), "user presence required");
    }

    function test_aMalformedSignatureIsFalseNeverARevert() public view {
        bytes32 d = keccak256("x");
        bytes memory good = signPasskey(PASSKEY_A, d);
        assertFalse(a.checkOwnerSignature(d, ""));
        assertFalse(a.checkOwnerSignature(d, hex"01"));
        assertFalse(a.checkOwnerSignature(d, hex"03aabb"));
        assertFalse(a.checkOwnerSignature(d, abi.encodePacked(uint8(1), new bytes(65))));
        bytes memory cut = new bytes(good.length - 40);
        for (uint256 i; i < cut.length; ++i) cut[i] = good[i];
        assertFalse(a.checkOwnerSignature(d, cut), "a truncated assertion");
        bytes memory wrongKey = abi.encodePacked(good);
        wrongKey[40] = bytes1(uint8(wrongKey[40]) ^ 1); // in y: another key
        assertFalse(a.checkOwnerSignature(d, wrongKey));
    }

    /// Decision 29: no EIP-1271. A contract wallet can't be added, and nothing it answers is a signature.
    /// An EIP-7702 delegated EOA still signs with its own key: accepted at the home.
    function test_anEip7702DelegatedWalletIsAccepted() public {
        address eoa = vm.addr(WALLET_B);
        vm.etch(eoa, abi.encodePacked(hex"ef0100", address(0x1234)));
        addNow(a, WALLET_A, wallet(WALLET_B));
        assertTrue(a.isCredential(wallet(WALLET_B)));
    }

    function test_aContractWalletIsNeverACredential() public {
        ContractWallet cw = new ContractWallet();
        uint256 nonce = a.recordNonceOf(wallet(WALLET_A));
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        Credential memory c = walletOf(address(cw));
        bytes32 d = typed(a, abi.encode(a.ADD_CREDENTIAL_TYPEHASH(), c.kind, c.x, c.y, nonce, deadline));
        vm.expectRevert(DepositAccount.BadCredential.selector);
        a.addCredential(c, nonce, deadline, signWallet(WALLET_A, d));
        assertFalse(a.checkOwnerSignature(d, abi.encodePacked(uint8(1), address(cw), new bytes(45))));
    }

    // ── record changes at the home ───────────────────────────────────────────────────────────

    /// Decision 31: an addition takes effect after 24 hours.
    function test_addACredentialAfter24Hours() public {
        assertFalse(a.isCredential(wallet(WALLET_B)));
        uint256 walletNonce = a.recordNonceOf(wallet(WALLET_A));
        addCredential(a, PASSKEY_A, wallet(WALLET_B));
        uint256 due = a.additionDue(wallet(WALLET_B));
        assertEq(due, vm.getBlockTimestamp() + 24 hours);
        assertEq(a.recordNonceOf(passkey(PASSKEY_A)), 1);
        assertEq(a.recordNonceOf(wallet(WALLET_A)), walletNonce, "each credential its own sequence");
        bytes32 d = keccak256("x");
        vm.warp(due - 1);
        assertFalse(a.isCredential(wallet(WALLET_B)), "pending");
        assertFalse(a.checkOwnerSignature(d, signWallet(WALLET_B, d)), "a pending credential can't sign");
        assertEq(a.version(), 1);
        assertEq(a.credentials().length, 2);
        vm.warp(due);
        assertTrue(a.isCredential(wallet(WALLET_B)));
        assertTrue(a.checkOwnerSignature(d, signWallet(WALLET_B, d)));
        assertEq(a.version(), 2);
        assertEq(a.credentials().length, 3);
        assertEq(a.additionDue(wallet(WALLET_B)), 0);
    }

    /// A thief with a stolen credential adds an accomplice; any honest credential cancels it within
    /// the 24 hours, and the accomplice never signs.
    function test_aThiefsAdditionIsCancelled() public {
        addCredential(a, WALLET_A, passkey(PASSKEY_B)); // WALLET_A stolen: PASSKEY_B is the thief's
        uint256 due = a.additionDue(passkey(PASSKEY_B));
        vm.expectRevert(DepositAccount.BadSignature.selector);
        this.cancelA(PASSKEY_B, passkey(PASSKEY_B), due); // the accomplice can't act yet
        cancelAddition(a, PASSKEY_A, passkey(PASSKEY_B), due);
        vm.warp(due + 1);
        assertFalse(a.isCredential(passkey(PASSKEY_B)));
        assertEq(a.additionDue(passkey(PASSKEY_B)), 0);
        assertEq(a.version(), 1);
        vm.expectRevert(DepositAccount.NothingPending.selector);
        this.cancelA(PASSKEY_A, passkey(PASSKEY_B), due); // a replay cancels nothing
    }

    function cancelA(uint256 signer, Credential memory c, uint256 due) external {
        cancelAddition(a, signer, c, due);
    }

    function test_anAdditionCannotBeCancelledOnceInEffect() public {
        addCredential(a, WALLET_A, wallet(WALLET_B));
        uint256 due = a.additionDue(wallet(WALLET_B));
        vm.warp(due);
        vm.expectRevert(DepositAccount.NothingPending.selector);
        this.cancelA(PASSKEY_A, wallet(WALLET_B), due);
    }

    function test_aRecordChangeIsConsumedOnceAndExpires() public {
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        Credential memory c = wallet(WALLET_B);
        // WALLET_A's record nonce 0 went on setUp's addition
        bytes32 d = typed(a, abi.encode(a.ADD_CREDENTIAL_TYPEHASH(), c.kind, c.x, c.y, uint256(1), deadline));
        bytes memory sig = signWallet(WALLET_A, d);
        vm.expectRevert(DepositAccount.BadSignature.selector); // the nonce is signed
        a.addCredential(c, 2, deadline, sig);
        a.addCredential(c, 1, deadline, sig);
        vm.expectRevert(DepositAccount.BadNonce.selector);
        a.addCredential(c, 1, deadline, sig);

        Credential memory p = passkey(PASSKEY_B);
        d = typed(a, abi.encode(a.ADD_CREDENTIAL_TYPEHASH(), p.kind, p.x, p.y, uint256(2), deadline));
        sig = signWallet(WALLET_A, d);
        vm.warp(deadline + 1);
        vm.expectRevert(DepositAccount.Expired.selector);
        a.addCredential(p, 2, deadline, sig);
    }

    function test_aRecordChangeSignedByAStrangerIsRefused() public {
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        Credential memory c = wallet(WALLET_B);
        bytes32 d = typed(a, abi.encode(a.ADD_CREDENTIAL_TYPEHASH(), c.kind, c.x, c.y, uint256(0), deadline));
        vm.expectRevert(DepositAccount.BadSignature.selector);
        a.addCredential(c, 0, deadline, signWallet(WALLET_B, d));
    }

    function test_atMostFourCredentialsAndNoDuplicate() public {
        vm.expectRevert(DepositAccount.AlreadyMember.selector);
        this.add(PASSKEY_A, passkey(PASSKEY_A));
        addCredential(a, WALLET_A, wallet(WALLET_B));
        addCredential(a, WALLET_A, passkey(PASSKEY_B));
        vm.expectRevert(DepositAccount.TooManyCredentials.selector);
        this.add(WALLET_A, wallet(0xC0FFEE));
    }

    function add(uint256 signer, Credential memory c) external {
        addCredential(a, signer, c);
    }

    function test_removeACredentialAfter24Hours() public {
        addNow(a, WALLET_A, wallet(WALLET_B));
        proposeRemoval(a, PASSKEY_A, wallet(WALLET_B));
        uint256 due = a.removalDue(wallet(WALLET_B));
        assertEq(due, vm.getBlockTimestamp() + 24 hours);
        assertEq(a.version(), 2, "a proposal is not a change");
        bytes32 d = keccak256("x");
        vm.warp(due - 1);
        assertTrue(a.checkOwnerSignature(d, signWallet(WALLET_B, d)), "valid until it takes effect");
        vm.warp(due);
        assertFalse(a.checkOwnerSignature(d, signWallet(WALLET_B, d)), "gone at 24 hours, settled or not");
        assertFalse(a.isCredential(wallet(WALLET_B)));
        assertEq(a.version(), 3);
        assertEq(a.credentials().length, 2);
        assertEq(a.removalDue(wallet(WALLET_B)), 0);
        // the next change settles it in storage
        setWithdrawal(a, WALLET_A, DEST);
        assertEq(a.version(), 3);
        assertEq(a.credentials().length, 2);
    }

    function test_aRemovalIsCancelledByAnotherCredential() public {
        addNow(a, WALLET_A, wallet(WALLET_B));
        proposeRemoval(a, PASSKEY_A, wallet(WALLET_B));
        uint256 due = a.removalDue(wallet(WALLET_B));
        cancelRemoval(a, WALLET_A, wallet(WALLET_B), due);
        assertEq(a.removalDue(wallet(WALLET_B)), 0);
        vm.warp(due + 1);
        assertTrue(a.isCredential(wallet(WALLET_B)));
        assertEq(a.version(), 2);
        // a cancel replayed, or of a removal no longer pending, cancels nothing
        vm.expectRevert(DepositAccount.NothingPending.selector);
        this.cancelR(WALLET_A, wallet(WALLET_B), due);
    }

    function cancelR(uint256 signer, Credential memory c, uint256 due) external {
        cancelRemoval(a, signer, c, due);
    }

    /// Decision 31: with two or more others standing, a credential can't save itself.
    function test_aRemovedCredentialCannotCancelItsOwnRemoval() public {
        addNow(a, WALLET_A, wallet(WALLET_B)); // three: WALLET_A, PASSKEY_A, WALLET_B (the thief's)
        proposeRemoval(a, PASSKEY_A, wallet(WALLET_B));
        uint256 due = a.removalDue(wallet(WALLET_B));
        vm.expectRevert(DepositAccount.SelfCancel.selector);
        this.cancelR(WALLET_B, wallet(WALLET_B), due);
        vm.warp(due);
        assertFalse(a.isCredential(wallet(WALLET_B)), "the owner's two honest credentials win");
    }

    /// The exception: a removal that would leave a single credential standing. Two credentials, one
    /// stolen: whoever proposes first can't win, so the target may cancel its own and they stand off.
    function test_theTwoCredentialStandOffStaysCancellableByTheTarget() public {
        proposeRemoval(a, WALLET_A, passkey(PASSKEY_A)); // WALLET_A stolen, proposing first
        uint256 due = a.removalDue(passkey(PASSKEY_A));
        cancelRemoval(a, PASSKEY_A, passkey(PASSKEY_A), due);
        vm.warp(due + 1);
        assertTrue(a.isCredential(passkey(PASSKEY_A)));
        // the honest one's removal of the thief is cancelled by the thief alike
        proposeRemoval(a, PASSKEY_A, wallet(WALLET_A));
        due = a.removalDue(wallet(WALLET_A));
        cancelRemoval(a, WALLET_A, wallet(WALLET_A), due);
        assertEq(a.removalDue(wallet(WALLET_A)), 0);
    }

    /// Pending removals count: three credentials, one removal already pending, the second target is
    /// then the last but one standing and may cancel its own.
    /// Removals proposed by OTHERS count: the thief (WALLET_B) proposes both honest credentials'
    /// removals; WALLET_A, left facing the thief alone, may cancel its own, then rescue PASSKEY_A.
    function test_aSelfCancelCountsRemovalsProposedByOthers() public {
        addNow(a, WALLET_A, wallet(WALLET_B));
        proposeRemoval(a, WALLET_B, passkey(PASSKEY_A));
        proposeRemoval(a, WALLET_B, wallet(WALLET_A));
        uint256 due = a.removalDue(wallet(WALLET_A));
        cancelRemoval(a, WALLET_A, wallet(WALLET_A), due); // only the thief stands besides it
        cancelRemoval(a, WALLET_A, passkey(PASSKEY_A), a.removalDue(passkey(PASSKEY_A)));
        assertEq(a.removalDue(wallet(WALLET_A)), 0);
        assertEq(a.removalDue(passkey(PASSKEY_A)), 0);
    }

    /// The verification's bypass, the honest credential proposing first: PASSKEY_A proposes the
    /// thief's removal; the thief, still in effect, proposes PASSKEY_A's to shrink the standing set,
    /// then tries to cancel its own. Its own proposal doesn't count: refused, and it is removed.
    function test_theSelfCancelBypassIsRefused_honestFirst() public {
        addNow(a, WALLET_A, wallet(WALLET_B)); // WALLET_B: the thief's
        proposeRemoval(a, PASSKEY_A, wallet(WALLET_B));
        proposeRemoval(a, WALLET_B, passkey(PASSKEY_A));
        uint256 due = a.removalDue(wallet(WALLET_B));
        vm.expectRevert(DepositAccount.SelfCancel.selector);
        this.cancelR(WALLET_B, wallet(WALLET_B), due);
        cancelRemoval(a, WALLET_A, passkey(PASSKEY_A), a.removalDue(passkey(PASSKEY_A)));
        vm.warp(due);
        assertFalse(a.isCredential(wallet(WALLET_B)));
        assertTrue(a.isCredential(passkey(PASSKEY_A)));
        assertTrue(a.isCredential(wallet(WALLET_A)));
    }

    /// The same bypass, the thief proposing first.
    function test_theSelfCancelBypassIsRefused_thiefFirst() public {
        addNow(a, WALLET_A, wallet(WALLET_B));
        proposeRemoval(a, WALLET_B, passkey(PASSKEY_A));
        proposeRemoval(a, PASSKEY_A, wallet(WALLET_B));
        uint256 due = a.removalDue(wallet(WALLET_B));
        vm.expectRevert(DepositAccount.SelfCancel.selector);
        this.cancelR(WALLET_B, wallet(WALLET_B), due);
        cancelRemoval(a, WALLET_A, passkey(PASSKEY_A), a.removalDue(passkey(PASSKEY_A)));
        vm.warp(due);
        assertFalse(a.isCredential(wallet(WALLET_B)));
        assertTrue(a.isCredential(passkey(PASSKEY_A)));
    }

    /// Per-credential nonces: a thief submitting changes can't void the owner's pending signatures.
    function test_oneCredentialsNonceNeverVoidsAnothers() public {
        addNow(a, WALLET_A, wallet(WALLET_B)); // the thief
        // the owner signs a removal of the thief, not yet submitted
        Credential memory t = wallet(WALLET_B);
        uint256 nonce = a.recordNonceOf(passkey(PASSKEY_A));
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = signPasskey(
            PASSKEY_A, typed(a, abi.encode(a.REMOVE_CREDENTIAL_TYPEHASH(), t.kind, t.x, t.y, nonce, deadline))
        );
        // the thief spends its own sequence on changes
        setWithdrawal(a, WALLET_B, DEST2);
        setWithdrawal(a, WALLET_B, DEST2);
        (uint256 ln, uint256 ld, bytes memory lsig) = revokeSig(a, PASSKEY_A, true); // a local one too
        (uint256 tn, uint256 td, bytes memory tsig) = revokeSig(a, WALLET_B, false);
        a.allowTransfer(tn, td, tsig);
        // the owner's signatures still stand
        a.proposeRemoval(t, nonce, deadline, sig);
        a.revokeTransfer(ln, ld, lsig);
        assertTrue(a.transferRevoked());
        assertGt(a.removalDue(t), 0);
    }

    /// A pending addition is cancelled, not removed, and doesn't count as standing.
    function test_aPendingAdditionIsNotRemovable() public {
        addCredential(a, WALLET_A, wallet(WALLET_B));
        vm.expectRevert(DepositAccount.NotMember.selector);
        this.remove(PASSKEY_A, wallet(WALLET_B));
    }

    function test_aRemovalCannotBeCancelledOnceInEffect() public {
        addNow(a, WALLET_A, wallet(WALLET_B));
        proposeRemoval(a, PASSKEY_A, wallet(WALLET_B));
        uint256 due = a.removalDue(wallet(WALLET_B));
        vm.warp(due);
        vm.expectRevert(DepositAccount.NothingPending.selector);
        this.cancelR(WALLET_A, wallet(WALLET_B), due);
    }

    function test_aRemovalIsSignedByAnotherAndNeverTheLast() public {
        vm.expectRevert(DepositAccount.SelfRemoval.selector);
        this.remove(WALLET_A, wallet(WALLET_A));
        vm.expectRevert(DepositAccount.NotMember.selector);
        this.remove(WALLET_A, wallet(WALLET_B));
        proposeRemoval(a, PASSKEY_A, wallet(WALLET_A));
        vm.expectRevert(DepositAccount.AlreadyPending.selector);
        this.remove(PASSKEY_A, wallet(WALLET_A));
        // the passkey would be the last one standing
        vm.expectRevert(DepositAccount.LastCredential.selector);
        this.remove(WALLET_A, passkey(PASSKEY_A));
    }

    function remove(uint256 signer, Credential memory c) external {
        proposeRemoval(a, signer, c);
    }

    /// Decision 32: the first address waits 24 hours too, cancellable.
    function test_theFirstWithdrawalAddressWaits24Hours() public {
        assertEq(a.withdrawalAddress(), address(0));
        setWithdrawal(a, PASSKEY_A, DEST);
        assertEq(a.withdrawalAddress(), address(0), "not at once");
        (address next, uint256 due) = a.pendingWithdrawalAddress();
        assertEq(next, DEST);
        assertEq(due, vm.getBlockTimestamp() + 24 hours);
        vm.warp(due - 1);
        assertEq(a.withdrawalAddress(), address(0));
        vm.warp(due);
        assertEq(a.withdrawalAddress(), DEST);
        assertEq(a.version(), 2);
    }

    function test_theFirstWithdrawalAddressIsCancelled() public {
        setWithdrawal(a, WALLET_A, DEST2); // a compromised web2, a blind signature
        (, uint256 due) = a.pendingWithdrawalAddress();
        cancelWithdrawal(a, PASSKEY_A, DEST2, due);
        vm.warp(due + 1);
        assertEq(a.withdrawalAddress(), address(0));
        assertEq(a.version(), 1);
    }

    function test_aWithdrawalAddressChangeWaits24Hours() public {
        setWithdrawalNow(a, PASSKEY_A, DEST);
        assertEq(a.version(), 2);
        setWithdrawal(a, WALLET_A, DEST2);
        assertEq(a.withdrawalAddress(), DEST, "a change waits");
        (address next, uint256 due) = a.pendingWithdrawalAddress();
        assertEq(next, DEST2);
        assertEq(due, vm.getBlockTimestamp() + 24 hours);
        vm.warp(due - 1);
        assertEq(a.withdrawalAddress(), DEST);
        vm.warp(due);
        assertEq(a.withdrawalAddress(), DEST2);
        assertEq(a.version(), 3);
        (next, due) = a.pendingWithdrawalAddress();
        assertEq(next, address(0));
    }

    function test_aWithdrawalAddressChangeIsCancelled() public {
        setWithdrawalNow(a, PASSKEY_A, DEST);
        setWithdrawal(a, WALLET_A, DEST2);
        (, uint256 due) = a.pendingWithdrawalAddress();
        vm.expectRevert(DepositAccount.NothingPending.selector);
        this.cancelW(PASSKEY_A, DEST, due); // names another change
        cancelWithdrawal(a, PASSKEY_A, DEST2, due);
        vm.warp(due + 1);
        assertEq(a.withdrawalAddress(), DEST);
        assertEq(a.version(), 2);
        vm.expectRevert(DepositAccount.NothingPending.selector);
        this.cancelW(PASSKEY_A, DEST2, due);
    }

    function cancelW(uint256 signer, address next, uint256 due) external {
        cancelWithdrawal(a, signer, next, due);
    }

    function test_theWithdrawalAddressIsNeverZero() public {
        vm.expectRevert(DepositAccount.ZeroAddress.selector);
        this.setW(WALLET_A, address(0));
    }

    function setW(uint256 signer, address next) external {
        setWithdrawal(a, signer, next);
    }

    // ── copies (§7.3) ────────────────────────────────────────────────────────────────────────

    function test_aCopyRefusesASignedChange() public {
        vm.chainId(HYPEREVM);
        assertFalse(a.isHome());
        vm.expectRevert(DepositAccount.NotHome.selector);
        this.add(WALLET_A, wallet(WALLET_B));
        vm.expectRevert(DepositAccount.NotHome.selector);
        this.setW(WALLET_A, DEST);
        vm.expectRevert(DepositAccount.NotHome.selector);
        this.remove(PASSKEY_A, wallet(WALLET_A));
        vm.expectRevert(DepositAccount.NotHome.selector);
        a.publish(3);
    }

    function test_publishSendsTheWholeRecordToTheSameAddress() public {
        setWithdrawalNow(a, PASSKEY_A, DEST);
        addNow(a, WALLET_A, passkey(PASSKEY_B));
        addCredential(a, WALLET_A, wallet(WALLET_B)); // pending: not in the record
        vm.prank(STRANGER);
        a.publish(19);
        assertEq(mt.lastDomain(), 19);
        assertEq(mt.lastRecipient(), self());
        assertEq(mt.lastCaller(), bytes32(0), "anyone relays");
        assertEq(mt.lastThreshold(), 2000);
        assertEq(mt.lastSender(), address(a));
        (bytes32 tag, uint64 v, uint64 at, address w, Credential[] memory creds) =
            abi.decode(mt.body(), (bytes32, uint64, uint64, address, Credential[]));
        assertEq(tag, a.RECORD_TAG());
        assertEq(at, vm.getBlockTimestamp(), "the publish time");
        assertEq(v, 3);
        assertEq(w, DEST);
        assertEq(creds.length, 3);
        vm.expectRevert(DepositAccount.BadDomain.selector);
        a.publish(3);
    }

    /// What publish settles first: a change whose 24 hours passed with no transaction since.
    function test_publishCarriesWhatIsInEffect() public {
        setWithdrawalNow(a, PASSKEY_A, DEST);
        setWithdrawal(a, PASSKEY_A, DEST2);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        a.publish(0);
        (, uint64 v,, address w,) = abi.decode(mt.body(), (bytes32, uint64, uint64, address, Credential[]));
        assertEq(v, 3);
        assertEq(w, DEST2);
    }

    function test_aCopyAppliesTheHomesRecordAndIgnoresAnOlderOne() public {
        setWithdrawalNow(a, PASSKEY_A, DEST);
        a.publish(19);
        bytes memory v1 = mt.body();
        addNow(a, WALLET_A, wallet(WALLET_B));
        a.publish(19);
        bytes memory v2 = mt.body();

        toCopyAtGenesis();
        assertEq(a.version(), 0);
        assertEq(a.withdrawalAddress(), address(0));
        deliver(v2);
        assertEq(a.version(), 3, "a late copy catches up with one message");
        assertEq(a.withdrawalAddress(), DEST);
        assertTrue(a.isCredential(wallet(WALLET_B)));
        assertTrue(a.isCredential(passkey(PASSKEY_A)));
        vm.recordLogs();
        deliver(v1);
        assertEq(a.version(), 3, "an older version is ignored");
        assertTrue(a.isCredential(wallet(WALLET_B)));
        assertEq(vm.getRecordedLogs().length, 1, "RecordIgnored, and the message is consumed");
        deliver(v2);
        assertEq(a.version(), 3, "the same version too");
    }

    /// Avalanche (domain 1, chain 43114) holds a copy like any deposit chain: the home publishes to
    /// domain 1, and the copy there applies the record and trusts the home's credentials.
    function test_theRecordIsCopiedToAvalanche() public {
        setWithdrawalNow(a, PASSKEY_A, DEST);
        addNow(a, WALLET_A, wallet(WALLET_B));
        a.publish(1);
        assertEq(mt.lastDomain(), 1);
        assertEq(mt.lastRecipient(), self());
        bytes memory body = mt.body();

        vm.revertToState(copyGenesis);
        vm.chainId(43114);
        assertFalse(a.isHome());
        assertFalse(a.synced());
        deliver(body);
        assertEq(a.version(), 3);
        assertEq(a.withdrawalAddress(), DEST);
        assertTrue(a.isCredential(wallet(WALLET_B)));
        bytes32 d = keccak256("x");
        assertTrue(a.checkOwnerSignature(d, signPasskey(PASSKEY_A, d)));
        vm.expectRevert(DepositAccount.NotHome.selector);
        this.setW(PASSKEY_A, DEST2);
    }

    function deliver(bytes memory body) internal {
        vm.prank(MT);
        assertTrue(a.handleReceiveFinalizedMessage(3, self(), 2000, body));
    }

    /// The verification's second finding: a thief publishes while still in the record; where no copy
    /// exists yet, Circle's message waits, relayable. After the thief's removal a copy is deployed and
    /// the thief relays the old message first. Its first record must be one published since it exists:
    /// the stale one is ignored, the copy stays unsynced, and the home's fresh publish syncs it.
    function test_aStaleRecordIsNeverACopysFirst() public {
        bytes32 bob = bytes32(uint256(ALICE) + 1);
        Credential[] memory owners = one(wallet(WALLET_A));
        uint256 before = vm.snapshotState(); // before Bob's account exists anywhere
        DepositAccount h = DepositAccount(f.deploy(bob, owners));
        addNow(h, WALLET_A, passkey(PASSKEY_A)); // the owner's second credential
        addNow(h, WALLET_A, wallet(WALLET_B)); // the thief's credential, in effect
        setWithdrawalNow(h, WALLET_B, DEST2); // and its address
        vm.prank(STRANGER);
        h.publish(19); // sent while the thief is in the record: no copy on 19 yet
        bytes memory stale = mt.body();
        proposeRemoval(h, PASSKEY_A, wallet(WALLET_B));
        setWithdrawal(h, PASSKEY_A, DEST);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        assertFalse(h.isCredential(wallet(WALLET_B)));
        uint256 t = vm.getBlockTimestamp();
        h.publish(19); // the engine deploys the copy first, then publishes: same second here
        bytes memory fresh = mt.body();

        vm.revertToState(before);
        vm.chainId(HYPEREVM);
        vm.warp(t);
        DepositAccount copy = DepositAccount(f.deploy(bob, owners)); // the copy, deployed after
        bytes32 me = bytes32(uint256(uint160(address(copy))));
        vm.prank(MT);
        assertTrue(copy.handleReceiveFinalizedMessage(3, me, 2000, stale), "consumed, not reverted");
        assertFalse(copy.synced(), "the stale record is not its first");
        bytes32 d = keccak256("x");
        assertFalse(copy.checkOwnerSignature(d, signWallet(WALLET_B, d)));
        assertEq(copy.withdrawalAddress(), address(0));

        vm.prank(MT);
        copy.handleReceiveFinalizedMessage(3, me, 2000, fresh); // the home's publish, sent at t
        assertTrue(copy.synced());
        assertEq(copy.version(), 5);
        assertEq(copy.withdrawalAddress(), DEST);
        assertFalse(copy.checkOwnerSignature(d, signWallet(WALLET_B, d)), "the removed credential");
        // and once in sync, the stale one (a lower version) is ignored
        vm.prank(MT);
        copy.handleReceiveFinalizedMessage(3, me, 2000, stale);
        assertEq(copy.withdrawalAddress(), DEST);
    }

    function test_aCopyAcceptsOnlyTheHomesOwnFinalizedMessage() public {
        setWithdrawal(a, PASSKEY_A, DEST);
        a.publish(19);
        bytes memory body = mt.body();
        vm.chainId(HYPEREVM);
        vm.expectRevert(DepositAccount.NotTransmitter.selector);
        vm.prank(STRANGER);
        a.handleReceiveFinalizedMessage(3, self(), 2000, body);
        vm.prank(MT);
        vm.expectRevert(DepositAccount.NotHomeMessage.selector);
        a.handleReceiveFinalizedMessage(0, self(), 2000, body); // another domain
        vm.prank(MT);
        vm.expectRevert(DepositAccount.NotHomeMessage.selector);
        a.handleReceiveFinalizedMessage(3, bytes32(uint256(uint160(STRANGER))), 2000, body); // another sender
        vm.prank(MT);
        vm.expectRevert(DepositAccount.NotFinalized.selector);
        a.handleReceiveFinalizedMessage(3, self(), 1000, body);
        vm.prank(MT);
        vm.expectRevert(DepositAccount.NotFinalized.selector);
        a.handleReceiveUnfinalizedMessage(3, self(), 2000, body);
        vm.prank(MT);
        vm.expectRevert(DepositAccount.BadMessage.selector);
        a.handleReceiveFinalizedMessage(3, self(), 2000, abi.encode(bytes32("other"), uint64(9), uint64(vm.getBlockTimestamp()), DEST, one(wallet(WALLET_B))));
    }

    function test_theHomeAcceptsNoRecordMessage() public {
        setWithdrawal(a, PASSKEY_A, DEST);
        a.publish(19);
        bytes memory body = mt.body();
        vm.prank(MT);
        vm.expectRevert(DepositAccount.NotCopy.selector);
        a.handleReceiveFinalizedMessage(3, self(), 2000, body);
    }

    /// §7.3: a removed credential stays valid on a copy until the publish arrives.
    function test_aRemovalReachesACopyByThePublish() public {
        uint256 genesis = vm.snapshotState();
        proposeRemoval(a, PASSKEY_A, wallet(WALLET_A));
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        a.publish(19);
        bytes memory body = mt.body();
        uint256 t = vm.getBlockTimestamp();
        vm.revertToState(genesis);
        vm.chainId(HYPEREVM);
        deliverRecord(a, 0, address(0), two(wallet(WALLET_A), passkey(PASSKEY_A))); // in sync at genesis
        vm.warp(t);
        bytes32 d = keccak256("x");
        assertTrue(a.checkOwnerSignature(d, signWallet(WALLET_A, d)), "still valid on the copy");
        deliver(body);
        assertFalse(a.checkOwnerSignature(d, signWallet(WALLET_A, d)), "gone once the record arrives");
        assertTrue(a.checkOwnerSignature(d, signPasskey(PASSKEY_A, d)));
    }

    /// The review's scenario: the home removes a credential; 8 days later a copy is deployed on a new
    /// chain from the genesis set. Until the home's record reaches it, it trusts NO credential (the
    /// removed one included): no signature, no local action, no wallet's own withdrawal.
    function test_aFreshCopyTrustsNoCredentialUntilTheRecordArrives() public {
        proposeRemoval(a, PASSKEY_A, wallet(WALLET_A));
        vm.warp(vm.getBlockTimestamp() + 8 days);
        a.publish(19);
        bytes memory body = mt.body();
        uint256 t = vm.getBlockTimestamp();
        toCopyAtGenesis(); // the account at its genesis, as a chain where it is deployed now
        vm.warp(t);
        vm.prank(TRANSFER);
        f.checkIn(); // the transfer key alive: the hatch shut
        DepositAccount copy = DepositAccount(f.deploy(ALICE, one(wallet(WALLET_A))));
        assertEq(address(copy), address(a));
        assertFalse(copy.synced());
        bytes32 d = keccak256("x");
        assertFalse(copy.checkOwnerSignature(d, signWallet(WALLET_A, d)), "the removed credential");
        assertFalse(copy.checkOwnerSignature(d, signPasskey(PASSKEY_A, d)), "even a kept one");
        assertFalse(copy.isCredential(wallet(WALLET_A)));
        (uint256 nonce, uint256 deadline, bytes memory sig) = revokeSig(copy, WALLET_A, true);
        vm.expectRevert(DepositAccount.NotSynced.selector);
        copy.revokeTransfer(nonce, deadline, sig);
        vm.prank(vm.addr(WALLET_A));
        vm.expectRevert(DepositAccount.NotSynced.selector);
        copy.withdraw(address(0), 0);

        deliver(body);
        assertTrue(copy.synced());
        assertEq(copy.version(), 2);
        assertFalse(copy.checkOwnerSignature(d, signWallet(WALLET_A, d)), "removed, as at the home");
        assertTrue(copy.checkOwnerSignature(d, signPasskey(PASSKEY_A, d)));
        (nonce, deadline, sig) = revokeSig(copy, PASSKEY_A, true);
        copy.revokeTransfer(nonce, deadline, sig);
        assertTrue(copy.transferRevoked());
    }

    /// The first record is taken whatever its version, the home's genesis (0) included; then only a
    /// higher one.
    function test_theFirstRecordIsTakenEvenAtVersionZero() public {
        toCopyAtGenesis();
        assertFalse(a.synced());
        deliverRecord(a, 0, address(0), one(passkey(PASSKEY_A)));
        assertTrue(a.synced());
        assertEq(a.version(), 0);
        assertFalse(a.isCredential(wallet(WALLET_A)));
        deliverRecord(a, 0, DEST, two(wallet(WALLET_A), passkey(PASSKEY_A)));
        assertEq(a.withdrawalAddress(), address(0), "the same version, ignored");
        vm.chainId(ARBITRUM);
        assertTrue(a.synced(), "the home is always in sync");
    }

    /// A local action at a copy is the copy's: its own nonce, its chain named.
    function test_localActionsNameTheirChain() public {
        (uint256 nonce, uint256 deadline, bytes memory sig) = revokeSig(a, WALLET_A, true);
        vm.chainId(HYPEREVM);
        deliverRecord(a, 0, address(0), two(wallet(WALLET_A), passkey(PASSKEY_A)));
        vm.expectRevert(DepositAccount.BadSignature.selector);
        a.revokeTransfer(nonce, deadline, sig);
        (nonce, deadline, sig) = revokeSig(a, WALLET_A, true);
        a.revokeTransfer(nonce, deadline, sig);
        assertTrue(a.transferRevoked());
        vm.expectRevert(DepositAccount.BadNonce.selector);
        a.revokeTransfer(nonce, deadline, sig);
    }

    /// A signature over another digest (a vault's BeginExit) is unaffected by any nonce here.
    function test_checkOwnerSignatureIgnoresTheNonces() public {
        bytes32 beginExit = keccak256("BeginExit(strategy, deadline)");
        bytes memory sig = signPasskey(PASSKEY_A, beginExit);
        (uint256 nonce, uint256 deadline, bytes memory r) = revokeSig(a, WALLET_A, true);
        a.revokeTransfer(nonce, deadline, r);
        addCredential(a, WALLET_A, wallet(WALLET_B));
        assertTrue(a.checkOwnerSignature(beginExit, sig));
    }

    function test_theDomainHasNoChainId() public {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,address verifyingContract)"),
                keccak256("DLTX Owner"),
                keccak256("1"),
                address(a)
            )
        );
        assertEq(a.domainSeparator(), expected);
        vm.chainId(HYPEREVM);
        assertEq(a.domainSeparator(), expected, "the same on every chain");
    }
}
