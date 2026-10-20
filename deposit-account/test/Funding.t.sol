// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {DepositAccount, StrategyGrant} from "../src/DepositAccount.sol";
import {DepositFactory} from "../src/DepositFactory.sol";
import {FixtureVaultFactory, Helpers, MockToken, MockTokenMessenger, MockTransmitter} from "./Helpers.sol";

/*
 * Amendment 1 (step-11e2-amendment-1-vault-factories.md §5): funding any vault factory the owner
 * trusts, on any deposit chain. The trusted-factory set (24 hours the first time, cancellable,
 * permanent), the allowance in USDC per (factory, strategy, configuration), `fund` paying only a
 * deployed vault its trusted factory registered to this owner, the dispatch of an authorisation to a
 * copy and the copy's handling of it, and the abandonment of money moved to another chain. No fork:
 * Arbitrum's and Ethereum's USDC, Circle's transmitter and messenger are mocks etched at their
 * addresses; the vault factory is the FIXTURE factory (the fork tests use slice 2's real one).
 */
contract FundingTest is Helpers {
    address constant ARB_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant ETH_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant HYPE_USDC = 0xb88339CB7199b77E23DB6E890353E22632Ba630f;
    address constant MT = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;
    address constant TM = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    bytes32 constant STRATEGY = keccak256("strategy A");
    bytes32 constant CONFIG = keccak256("strategy A's configuration");

    DepositFactory f;
    DepositAccount a;
    FixtureVaultFactory vf;
    MockTransmitter mt;
    uint256 ready; // a snapshot: the home set up, nothing authorised

    function setUp() public {
        vm.chainId(42161);
        f = deployFactory();
        vm.prank(RECOVERY);
        f.setTransferKey(TRANSFER);
        a = deployTwo(f, ALICE, WALLET_A, passkey(PASSKEY_A));
        vm.etch(ARB_USDC, address(new MockToken()).code);
        vm.etch(ETH_USDC, address(new MockToken()).code);
        vm.etch(HYPE_USDC, address(new MockToken()).code);
        vm.etch(MT, address(new MockTransmitter()).code);
        vm.etch(TM, address(new MockTokenMessenger()).code);
        mt = MockTransmitter(MT);
        vf = new FixtureVaultFactory();
        MockToken(ARB_USDC).mint(address(a), 1_000e6);
        setWithdrawalNow(a, PASSKEY_A, DEST);
        vm.prank(TRANSFER);
        f.checkIn();
        ready = vm.snapshotState();
    }

    function usdc(address token, address who) internal view returns (uint256) {
        return MockToken(token).balanceOf(who);
    }

    /// The trust's 24 hours, then the domain-3 grant made under it applied.
    function trustedWith(uint256 amount) internal returns (address vault) {
        uint256 id = authorise(a, PASSKEY_A, address(vf), 3, STRATEGY, CONFIG, amount);
        vm.warp(dueOf(a, address(vf), 3));
        a.applyAuthorisation(id);
        vault = vf.create(STRATEGY, address(a), CONFIG);
    }

    // ── trusting a factory (§2.2) ────────────────────────────────────────────────────────────

    function test_anUntrustedFactoryWaits24HoursThenItsGrantApplies() public {
        uint256 id = authorise(a, PASSKEY_A, address(vf), 3, STRATEGY, CONFIG, 300e6);
        assertEq(id, 1);
        uint256 due = dueOf(a, address(vf), 3);
        assertEq(due, vm.getBlockTimestamp() + 24 hours);
        assertFalse(a.isTrusted(address(vf), 3));
        assertEq(a.allowanceOf(address(vf), STRATEGY, CONFIG), 0, "nothing applies while pending");
        address vault = vf.create(STRATEGY, address(a), CONFIG);
        vm.prank(TRANSFER);
        vm.expectRevert(DepositAccount.NotTrusted.selector);
        a.fund(address(vf), vault, 1e6);
        vm.expectRevert(DepositAccount.NotTrusted.selector);
        a.applyAuthorisation(id);
        vm.warp(due - 1);
        assertFalse(a.isTrusted(address(vf), 3));
        vm.warp(due);
        assertTrue(a.isTrusted(address(vf), 3));
        vm.prank(STRANGER); // anyone applies it
        a.applyAuthorisation(id);
        assertEq(a.allowanceOf(address(vf), STRATEGY, CONFIG), 300e6);
        vm.expectRevert(DepositAccount.AlreadyApplied.selector);
        a.applyAuthorisation(id);
        vm.prank(TRANSFER);
        a.fund(address(vf), vault, 300e6);
        assertEq(usdc(ARB_USDC, vault), 300e6);
        assertEq(a.allowanceOf(address(vf), STRATEGY, CONFIG), 0);
    }

    function test_aTrustedFactorysGrantIsImmediate() public {
        trustedWith(100e6);
        bytes32 other = keccak256("strategy A, second");
        authorise(a, WALLET_A, address(vf), 3, other, CONFIG, 50e6);
        assertEq(a.allowanceOf(address(vf), other, CONFIG), 50e6, "at once, the trust is permanent");
        assertEq(dueOf(a, address(vf), 3), vm.getBlockTimestamp(), "unchanged");
    }

    /// Two grants while the trust is pending share its one 24 hours; neither restarts it.
    function test_grantsWhileTrustIsPendingShareItsDueTime() public {
        authorise(a, PASSKEY_A, address(vf), 3, STRATEGY, CONFIG, 1e6);
        uint256 due = dueOf(a, address(vf), 3);
        vm.warp(vm.getBlockTimestamp() + 10 hours);
        uint256 id2 = authorise(a, WALLET_A, address(vf), 3, STRATEGY, CONFIG, 2e6);
        assertEq(dueOf(a, address(vf), 3), due);
        assertEq(a.grant(id2).trustEpoch, a.grant(1).trustEpoch);
    }

    function test_aPendingTrustIsCancelledByAnyCredentialAndVoidsItsGrants() public {
        uint256 id = authorise(a, WALLET_A, address(vf), 3, STRATEGY, CONFIG, 300e6); // a blind signature
        uint256 due = dueOf(a, address(vf), 3);
        cancelTrust(a, PASSKEY_A, address(vf), 3, due);
        assertEq(dueOf(a, address(vf), 3), 0);
        vm.warp(due + 1);
        assertFalse(a.isTrusted(address(vf), 3));
        vm.expectRevert(DepositAccount.NotTrusted.selector);
        a.applyAuthorisation(id);
        vm.expectRevert(DepositAccount.NothingPending.selector);
        this.cancelT(PASSKEY_A, due); // a replay cancels nothing
        // trusted later on purpose: the cancelled grant stays void, only the new one applies
        uint256 id2 = authorise(a, PASSKEY_A, address(vf), 3, STRATEGY, CONFIG, 10e6);
        vm.warp(dueOf(a, address(vf), 3));
        vm.expectRevert(DepositAccount.NotTrusted.selector);
        a.applyAuthorisation(id);
        a.applyAuthorisation(id2);
        assertEq(a.allowanceOf(address(vf), STRATEGY, CONFIG), 10e6);
    }

    function cancelT(uint256 signer, uint256 due) external {
        cancelTrust(a, signer, address(vf), 3, due);
    }

    function test_aTrustInEffectCannotBeCancelled() public {
        authorise(a, PASSKEY_A, address(vf), 3, STRATEGY, CONFIG, 1e6);
        uint256 due = dueOf(a, address(vf), 3);
        vm.warp(due);
        vm.expectRevert(DepositAccount.NothingPending.selector);
        this.cancelT(PASSKEY_A, due);
        assertTrue(a.isTrusted(address(vf), 3));
    }

    function test_anAuthorisationIsTheHomesLocalAction() public {
        (StrategyGrant memory g, bytes memory sig) = grantSig(a, WALLET_B, address(vf), 3, STRATEGY, CONFIG, 1e6);
        vm.expectRevert(DepositAccount.BadSignature.selector);
        a.authoriseStrategy(g, sig);
        (g, sig) = grantSig(a, PASSKEY_A, address(vf), 5, STRATEGY, CONFIG, 1e6);
        vm.expectRevert(DepositAccount.BadDomain.selector); // Solana: not a deposit chain
        a.authoriseStrategy(g, sig);
        (g, sig) = grantSig(a, PASSKEY_A, address(vf), 3, STRATEGY, CONFIG, 0);
        vm.expectRevert(DepositAccount.BadAmount.selector);
        a.authoriseStrategy(g, sig);
        (g, sig) = grantSig(a, PASSKEY_A, address(vf), 3, STRATEGY, CONFIG, 1e6);
        a.authoriseStrategy(g, sig);
        vm.expectRevert(DepositAccount.BadNonce.selector);
        a.authoriseStrategy(g, sig);
        vm.chainId(1);
        deliverRecord(a, 1, DEST, two(wallet(WALLET_A), passkey(PASSKEY_A)));
        (g, sig) = grantSig(a, PASSKEY_A, address(vf), 0, STRATEGY, CONFIG, 1e6);
        vm.expectRevert(DepositAccount.NotHome.selector);
        a.authoriseStrategy(g, sig);
    }

    /// The verification's first point: trust is per (factory, domain). A factory trusted for Ethereum
    /// gives a domain-3 grant naming the same address no shortcut: its own 24 hours.
    function test_aTrustForAnotherDomainGivesTheHomeNothing() public {
        uint256 eth = authorise(a, PASSKEY_A, address(vf), 0, STRATEGY, CONFIG, 1e6);
        vm.warp(dueOf(a, address(vf), 0));
        assertTrue(a.isTrusted(address(vf), 0));
        a.dispatchAuthorisation(eth);
        uint256 id = authorise(a, PASSKEY_A, address(vf), 3, STRATEGY, CONFIG, 100e6);
        assertEq(a.allowanceOf(address(vf), STRATEGY, CONFIG), 0, "not applied at once");
        assertFalse(a.isTrusted(address(vf), 3));
        assertEq(dueOf(a, address(vf), 3), vm.getBlockTimestamp() + 24 hours, "its own first 24 hours");
        address vault = vf.create(STRATEGY, address(a), CONFIG);
        vm.prank(TRANSFER);
        vm.expectRevert(DepositAccount.NotTrusted.selector);
        a.fund(address(vf), vault, 1e6);
        vm.expectRevert(DepositAccount.NotTrusted.selector);
        a.applyAuthorisation(id);
        vm.warp(dueOf(a, address(vf), 3));
        a.applyAuthorisation(id);
        vm.prank(TRANSFER);
        a.fund(address(vf), vault, 100e6);
    }

    /// The verification's second point: a cancel and a new grant in the same second (so the same due
    /// time): the cancelled grant's trust epoch is gone for good.
    function test_aCancelledGrantNeverRevivesEvenReGrantedInTheSameSecond() public {
        uint256 old = authorise(a, WALLET_A, address(vf), 3, STRATEGY, CONFIG, 300e6);
        uint256 oldEth = authorise(a, WALLET_A, address(vf), 0, STRATEGY, CONFIG, 300e6);
        (uint256 due, uint256 epoch) = a.trustOf(address(vf), 3);
        cancelTrust(a, PASSKEY_A, address(vf), 3, due);
        (uint256 dueEth,) = a.trustOf(address(vf), 0);
        cancelTrust(a, PASSKEY_A, address(vf), 0, dueEth);
        uint256 fresh = authorise(a, PASSKEY_A, address(vf), 3, STRATEGY, CONFIG, 10e6);
        uint256 freshEth = authorise(a, PASSKEY_A, address(vf), 0, STRATEGY, CONFIG, 10e6);
        (uint256 due2, uint256 epoch2) = a.trustOf(address(vf), 3);
        assertEq(due2, due, "the same second, the same due time");
        assertEq(epoch2, epoch + 1, "a new epoch");
        vm.warp(due);
        vm.expectRevert(DepositAccount.NotTrusted.selector);
        a.applyAuthorisation(old);
        vm.expectRevert(DepositAccount.NotTrusted.selector);
        a.dispatchAuthorisation(oldEth);
        a.applyAuthorisation(fresh);
        a.dispatchAuthorisation(freshEth);
        assertEq(a.allowanceOf(address(vf), STRATEGY, CONFIG), 10e6);
    }

    /// The verification's third point: one grant is at most 2^128 − 1, and a copy's sum saturates, so no
    /// authorisation message can revert forever.
    function test_anAbsurdGrantIsRefusedAndACopysSumSaturates() public {
        uint256 max = a.MAX_GRANT();
        assertEq(max, type(uint128).max);
        (StrategyGrant memory g, bytes memory sig) = grantSig(a, PASSKEY_A, address(vf), 0, STRATEGY, CONFIG, max + 1);
        vm.expectRevert(DepositAccount.BadAmount.selector);
        a.authoriseStrategy(g, sig);
        authorise(a, PASSKEY_A, address(vf), 0, STRATEGY, CONFIG, max);

        toEthereumCopy();
        deliverRecord(a, 1, DEST, two(wallet(WALLET_A), passkey(PASSKEY_A)));
        // even a forged message (Circle's stated trust) with an absurd amount can't jam the next ones
        deliverAuth(abi.encode(a.AUTH_TAG(), uint256(1), address(vf), STRATEGY, CONFIG, type(uint256).max));
        deliverAuth(abi.encode(a.AUTH_TAG(), uint256(2), address(vf), STRATEGY, CONFIG, uint256(1)));
        assertEq(a.allowanceOf(address(vf), STRATEGY, CONFIG), type(uint256).max);
        assertTrue(a.authorisationApplied(2));
    }

    // ── funding (§2.3) ───────────────────────────────────────────────────────────────────────

    function test_fundingRefusesEverythingButARegisteredVaultOfATrustedFactory() public {
        address vault = trustedWith(100e6);
        FixtureVaultFactory untrusted = new FixtureVaultFactory();
        address other = untrusted.create(STRATEGY, address(a), CONFIG);
        vm.startPrank(TRANSFER);
        vm.expectRevert(DepositAccount.NotTrusted.selector);
        a.fund(address(untrusted), other, 1e6); // a factory the owner never trusted
        vf.register(DEST2, address(a), STRATEGY, CONFIG);
        vm.expectRevert(DepositAccount.NotOwnVault.selector);
        a.fund(address(vf), DEST2, 1e6); // an address with no code
        vm.expectRevert(DepositAccount.NotOwnVault.selector);
        a.fund(address(vf), other, 1e6); // a vault this factory didn't create
        address theirs = vf.create(STRATEGY, address(0xA11CE5), CONFIG);
        vm.expectRevert(DepositAccount.NotOwnVault.selector);
        a.fund(address(vf), theirs, 1e6); // registered to another owner
        vm.expectRevert(DepositAccount.AllowanceExceeded.selector);
        a.fund(address(vf), vault, 100e6 + 1);
        vm.stopPrank();
        vm.prank(vm.addr(WALLET_A));
        vm.expectRevert(DepositAccount.NotAllowed.selector);
        a.fund(address(vf), vault, 1e6);
        (uint256 nonce, uint256 deadline, bytes memory sig) = revokeSig(a, PASSKEY_A, true);
        a.revokeTransfer(nonce, deadline, sig);
        vm.prank(TRANSFER);
        vm.expectRevert(DepositAccount.NotAllowed.selector);
        a.fund(address(vf), vault, 1e6);
        assertEq(usdc(ARB_USDC, address(a)), 1_000e6);
    }

    function test_fundingNeedsAWithdrawalAddressInEffect() public {
        bytes32 bob = bytes32(uint256(ALICE) + 1);
        DepositAccount b = DepositAccount(f.deploy(bob, one(passkey(PASSKEY_A))));
        MockToken(ARB_USDC).mint(address(b), 10e6);
        uint256 id = authorise(b, PASSKEY_A, address(vf), 3, STRATEGY, CONFIG, 10e6);
        vm.warp(dueOf(b, address(vf), 3));
        b.applyAuthorisation(id);
        address vault = vf.create(STRATEGY, address(b), CONFIG);
        vm.prank(TRANSFER);
        vm.expectRevert(DepositAccount.NoWithdrawalAddress.selector);
        b.fund(address(vf), vault, 10e6);
        setWithdrawal(b, PASSKEY_A, DEST);
        vm.prank(TRANSFER);
        vm.expectRevert(DepositAccount.NoWithdrawalAddress.selector); // the first address still pending
        b.fund(address(vf), vault, 10e6);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        vm.prank(TRANSFER);
        b.fund(address(vf), vault, 10e6);
        assertEq(usdc(ARB_USDC, vault), 10e6);
    }

    /// One allowance per (factory, strategy, configuration): never shared with a sibling.
    function test_theAllowanceIsPerFactoryStrategyAndConfiguration() public {
        address vault = trustedWith(100e6);
        FixtureVaultFactory second = new FixtureVaultFactory();
        uint256 id = authorise(a, PASSKEY_A, address(second), 3, keccak256("strategy B"), CONFIG, 1e6);
        vm.warp(dueOf(a, address(second), 3));
        a.applyAuthorisation(id);
        address sameKeysElsewhere = second.create(STRATEGY, address(a), CONFIG);
        address otherStrategy = vf.create(keccak256("strategy C"), address(a), CONFIG);
        address otherConfig = vf.create(STRATEGY, address(a), keccak256("another configuration"));
        vm.startPrank(TRANSFER);
        vm.expectRevert(DepositAccount.AllowanceExceeded.selector);
        a.fund(address(second), sameKeysElsewhere, 1e6);
        vm.expectRevert(DepositAccount.AllowanceExceeded.selector);
        a.fund(address(vf), otherStrategy, 1e6);
        vm.expectRevert(DepositAccount.AllowanceExceeded.selector);
        a.fund(address(vf), otherConfig, 1e6);
        a.fund(address(vf), vault, 100e6);
        vm.stopPrank();
        assertEq(a.vaultKey(address(vf), STRATEGY, CONFIG), keccak256(abi.encode(address(vf), STRATEGY, CONFIG)));
    }

    /// The recovery key has no say: it can't trust a factory, fund, or reach past the allowance even by
    /// making itself the transfer key.
    function test_theRecoveryKeyCannotAffectFunding() public {
        address vault = trustedWith(100e6);
        FixtureVaultFactory evil = new FixtureVaultFactory();
        address evilVault = evil.create(STRATEGY, address(a), CONFIG);
        vm.prank(RECOVERY);
        vm.expectRevert(DepositAccount.NotAllowed.selector);
        a.fund(address(vf), vault, 1e6);
        vm.prank(RECOVERY);
        f.setTransferKey(RECOVERY);
        vm.startPrank(RECOVERY);
        vm.expectRevert(DepositAccount.NotTrusted.selector);
        a.fund(address(evil), evilVault, 1e6);
        vm.expectRevert(DepositAccount.AllowanceExceeded.selector);
        a.fund(address(vf), vault, 100e6 + 1);
        vm.stopPrank();
        assertFalse(a.isTrusted(address(evil), 3));
    }

    // ── another chain (§2.4) ─────────────────────────────────────────────────────────────────

    function test_aGrantForAnotherDomainIsOnlyRecordedThenDispatched() public {
        uint256 id = authorise(a, PASSKEY_A, address(vf), 0, STRATEGY, CONFIG, 250e6);
        assertEq(a.allowanceOf(address(vf), STRATEGY, CONFIG), 0, "never added at the home");
        vm.expectRevert(DepositAccount.NotTrusted.selector);
        a.dispatchAuthorisation(id); // before the trust is due
        vm.expectRevert(DepositAccount.BadDomain.selector);
        a.applyAuthorisation(id);
        vm.warp(dueOf(a, address(vf), 0));
        vm.prank(STRANGER);
        a.dispatchAuthorisation(id);
        assertEq(a.allowanceOf(address(vf), STRATEGY, CONFIG), 0);
        assertEq(mt.lastDomain(), 0);
        assertEq(mt.lastRecipient(), bytes32(uint256(uint160(address(a)))));
        assertEq(mt.lastCaller(), bytes32(0));
        assertEq(mt.lastThreshold(), 2000);
        (bytes32 tag, uint256 gid, address factory, bytes32 sid, bytes32 ch, uint256 amount) =
            abi.decode(mt.body(), (bytes32, uint256, address, bytes32, bytes32, uint256));
        assertEq(tag, a.AUTH_TAG());
        assertEq(gid, id);
        assertEq(factory, address(vf));
        assertEq(sid, STRATEGY);
        assertEq(ch, CONFIG);
        assertEq(amount, 250e6);
        vm.expectRevert(DepositAccount.NoGrant.selector);
        a.dispatchAuthorisation(99);
        uint256 home = authorise(a, PASSKEY_A, address(vf), 3, STRATEGY, CONFIG, 1e6);
        vm.expectRevert(DepositAccount.BadDomain.selector);
        a.dispatchAuthorisation(home);
    }

    /// Dispatches grant `id` and returns the message body Circle would carry.
    function dispatched(uint256 id) internal returns (bytes memory) {
        a.dispatchAuthorisation(id);
        return mt.body();
    }

    /// The home's record and authorisations, then the Ethereum copy (the same account, its state
    /// reset to before any of it, as on a chain of its own).
    function toEthereumCopy() internal {
        vm.revertToState(ready);
        vm.chainId(1);
    }

    function deliverAuth(bytes memory body) internal {
        vm.prank(MT);
        assertTrue(a.handleReceiveFinalizedMessage(3, bytes32(uint256(uint160(address(a)))), 2000, body));
    }

    function test_aCopyTakesAnAuthorisationOnceAndFundsItsVault() public {
        uint256 id = authorise(a, PASSKEY_A, address(vf), 0, STRATEGY, CONFIG, 250e6);
        vm.warp(dueOf(a, address(vf), 0));
        bytes memory body = dispatched(id);
        bytes memory again = dispatched(id); // a redispatch: the same id
        assertEq(keccak256(again), keccak256(body));
        uint256 t = vm.getBlockTimestamp();

        toEthereumCopy();
        vm.warp(t);
        vm.prank(MT);
        vm.expectRevert(DepositAccount.NotSynced.selector); // an unsynced copy: stays relayable
        a.handleReceiveFinalizedMessage(3, bytes32(uint256(uint160(address(a)))), 2000, body);
        deliverRecord(a, 1, DEST, two(wallet(WALLET_A), passkey(PASSKEY_A)));
        vm.prank(MT);
        vm.expectRevert(DepositAccount.NotHomeMessage.selector);
        a.handleReceiveFinalizedMessage(0, bytes32(uint256(uint160(address(a)))), 2000, body);
        vm.prank(MT);
        vm.expectRevert(DepositAccount.NotFinalized.selector);
        a.handleReceiveFinalizedMessage(3, bytes32(uint256(uint160(address(a)))), 1000, body);
        vm.prank(STRANGER);
        vm.expectRevert(DepositAccount.NotTransmitter.selector);
        a.handleReceiveFinalizedMessage(3, bytes32(uint256(uint160(address(a)))), 2000, body);

        assertFalse(a.isTrusted(address(vf), 0));
        deliverAuth(body);
        assertTrue(a.authorisationApplied(id));
        assertTrue(a.isTrusted(address(vf), 0), "trusted on this chain at once");
        assertEq(a.allowanceOf(address(vf), STRATEGY, CONFIG), 250e6);

        // the money arrives by the home's burn to this same address, then the copy funds the vault
        MockToken(ETH_USDC).mint(address(a), 250e6);
        address vault = vf.create(STRATEGY, address(a), CONFIG);
        vm.prank(TRANSFER);
        a.fund(address(vf), vault, 250e6);
        assertEq(usdc(ETH_USDC, vault), 250e6);

        // a redispatch after spending adds nothing
        deliverAuth(again);
        assertEq(a.allowanceOf(address(vf), STRATEGY, CONFIG), 0);
    }

    /// HyperEVM (domain 19) is a deposit chain: the home accepts an authorisation for it, only
    /// records it, and dispatches it once the factory's trust for domain 19 is in effect.
    function test_anAuthorisationForHyperEvmIsAccepted() public {
        uint256 id = authorise(a, PASSKEY_A, address(vf), 19, STRATEGY, CONFIG, 250e6);
        assertEq(a.grant(id).domain, 19);
        assertEq(a.allowanceOf(address(vf), STRATEGY, CONFIG), 0, "never added at the home");
        assertFalse(a.isTrusted(address(vf), 19));
        vm.warp(dueOf(a, address(vf), 19));
        assertTrue(a.isTrusted(address(vf), 19));
        assertFalse(a.isTrusted(address(vf), 3), "a trust for HyperEVM gives the home nothing");
        a.dispatchAuthorisation(id);
        assertEq(mt.lastDomain(), 19);
        assertEq(mt.lastRecipient(), bytes32(uint256(uint160(address(a)))));
    }

    /// Amendment 1 §5's copy flow on HyperEVM: the home's dispatched authorisation, then the copy's
    /// record and that authorisation, then the money burned there, then `fund` (the FIXTURE factory).
    function test_aHyperEvmCopyTakesAnAuthorisationAndFundsItsVault() public {
        uint256 id = authorise(a, PASSKEY_A, address(vf), 19, STRATEGY, CONFIG, 250e6);
        vm.warp(dueOf(a, address(vf), 19));
        bytes memory body = dispatched(id);
        uint256 t = vm.getBlockTimestamp();

        vm.revertToState(ready);
        vm.chainId(999);
        vm.warp(t);
        deliverRecord(a, 1, DEST, two(wallet(WALLET_A), passkey(PASSKEY_A)));
        assertFalse(a.isTrusted(address(vf), 19));
        deliverAuth(body);
        assertTrue(a.authorisationApplied(id));
        assertTrue(a.isTrusted(address(vf), 19), "trusted on this chain at once");
        assertEq(a.allowanceOf(address(vf), STRATEGY, CONFIG), 250e6);

        MockToken(HYPE_USDC).mint(address(a), 250e6); // the home's burn lands
        address vault = vf.create(STRATEGY, address(a), CONFIG);
        vm.prank(TRANSFER);
        a.fund(address(vf), vault, 250e6);
        assertEq(usdc(HYPE_USDC, vault), 250e6);
        assertEq(a.allowanceOf(address(vf), STRATEGY, CONFIG), 0);
    }

    /// Two distinct grants with identical factory, strategy, configuration and amount add twice: each
    /// has its own id.
    function test_twoIdenticalGrantsAddTwice() public {
        uint256 id1 = authorise(a, PASSKEY_A, address(vf), 0, STRATEGY, CONFIG, 100e6);
        uint256 id2 = authorise(a, PASSKEY_A, address(vf), 0, STRATEGY, CONFIG, 100e6);
        assertEq(id2, id1 + 1);
        vm.warp(dueOf(a, address(vf), 0));
        bytes memory b1 = dispatched(id1);
        bytes memory b2 = dispatched(id2);
        toEthereumCopy();
        deliverRecord(a, 1, DEST, two(wallet(WALLET_A), passkey(PASSKEY_A)));
        deliverAuth(b1);
        deliverAuth(b2);
        deliverAuth(b1);
        assertEq(a.allowanceOf(address(vf), STRATEGY, CONFIG), 200e6);
    }

    /// Abandonment (§2.4, §5): the home burns USDC to the user's own address on Ethereum, it lands, and
    /// DLTX stops. The money is withdrawable there with no owner signature: by a wallet credential, and
    /// by anyone once the transfer key has not checked in for 7 days. The copy needs its record, which
    /// anyone may publish and relay without a signature.
    function test_moneyBurnedToTheUsersOwnAddressElsewhereStaysWithdrawable() public {
        vm.prank(TRANSFER);
        a.convertBurn(600e6, 0);
        MockTokenMessenger m = MockTokenMessenger(TM);
        assertEq(m.mintRecipient(), bytes32(uint256(uint160(address(a)))), "the user's own address");
        vm.prank(STRANGER);
        a.publish(0);
        bytes memory record = mt.body();
        uint256 t = vm.getBlockTimestamp();

        toEthereumCopy();
        vm.warp(t);
        vm.prank(MT);
        a.handleReceiveFinalizedMessage(3, bytes32(uint256(uint160(address(a)))), 2000, record);
        MockToken(ETH_USDC).mint(address(a), 600e6); // Circle's mint lands
        vm.prank(vm.addr(WALLET_A));
        a.withdraw(ETH_USDC, 100e6);
        assertEq(usdc(ETH_USDC, DEST), 100e6);
        vm.warp(vm.getBlockTimestamp() + 7 days); // no check-in since: the hatch
        vm.prank(STRANGER);
        a.withdraw(ETH_USDC, 500e6);
        assertEq(usdc(ETH_USDC, DEST), 600e6);
    }
}
