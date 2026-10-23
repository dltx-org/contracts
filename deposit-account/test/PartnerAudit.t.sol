// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {DepositAccount, Withdrawal} from "../src/DepositAccount.sol";
import {DepositAccountState} from "../src/DepositAccountState.sol";
import {MockToken, MockTokenMessenger} from "./Helpers.sol";
import {OwnerRecordTest} from "./OwnerRecord.t.sol";
import {MoneyTest} from "./Money.t.sol";

/// The operator's partner's audit of c64337f (2026-10-20), the deposit account's findings. Each test is the
/// partner's reproduction, adapted to assert the FIXED behaviour (docs/architecture/rework/research/
/// contracts-security-review.md §7).
contract PartnerAuditRecordTest is OwnerRecordTest {
    /// M1: a copy's record expires RECORD_TTL after the home published it. The partner's scenario: the
    /// copy holds the old record (two credentials, DEST); at the home WALLET_A is removed and the address
    /// replaced, and that record never reaches the copy. Within the 30 days the old record still stands
    /// (the bound); past them the copy reads as unsynced: the removed key signs nothing, no withdrawal
    /// pays the old address, by anyone, until a fresh publish arrives.
    function test_audit_initializedCopyKeepsRemovedOwnerAndOldDestination() public {
        // the home: the old record (WALLET_A, PASSKEY_A, DEST), published at t0
        setWithdrawalNow(a, PASSKEY_A, DEST);
        uint256 t0 = vm.getBlockTimestamp();
        rec(a).publish(19);
        bytes memory oldRecord = mt.body();
        // the home: WALLET_A removed, the address replaced; a fresh publish 31 days after t0
        proposeRemoval(a, PASSKEY_A, wallet(WALLET_A));
        setWithdrawal(a, PASSKEY_A, DEST2);
        uint256 late = t0 + 31 days;
        vm.warp(late);
        rec(a).publish(19);
        bytes memory fresh = mt.body();

        // the copy, at the old record
        toCopyAtGenesis();
        vm.warp(t0);
        deliver(oldRecord);
        vm.deal(address(a), 100 ether);
        vm.prank(TRANSFER);
        f.checkIn(supported()); // the transfer key alive: the hatch shut

        // within the 30 days, the old record stands (the bound the expiry sets)
        vm.warp(t0 + 30 days);
        bytes32 d = keccak256("x");
        assertTrue(a.checkOwnerSignature(d, signWallet(WALLET_A, d)), "the bound: valid for 30 days");

        // a second later, and a year later: expired
        for (uint256 i; i < 2; ++i) {
            vm.warp(i == 0 ? t0 + 30 days + 1 : t0 + 365 days);
            vm.prank(TRANSFER);
            f.checkIn(supported());
            assertFalse(a.synced(), "the copy expired");
            assertFalse(a.checkOwnerSignature(d, signWallet(WALLET_A, d)), "the removed key signs nothing");
            assertFalse(a.isCredential(wallet(WALLET_A)));
            assertEq(a.withdrawalAddress(), address(0), "no address named");
            Withdrawal memory w =
                Withdrawal(address(0), 100e6, DEST, 0, address(0), 0, vm.getBlockTimestamp() + 1 hours);
            bytes memory sig = signWithdrawal(a, WALLET_A, w);
            vm.expectRevert(DepositAccountState.NotSynced.selector);
            a.withdrawSigned(w, 0, sig);
            vm.prank(TRANSFER);
            vm.expectRevert(DepositAccountState.NotSynced.selector);
            a.withdraw(address(0), 100e6);
            vm.prank(vm.addr(WALLET_A));
            vm.expectRevert(DepositAccountState.NotSynced.selector);
            a.withdraw(address(0), 100e6);
        }
        assertEq(DEST.balance, 0, "nothing paid to the replaced address");
        // the old record relayed again renews nothing
        deliver(oldRecord);
        assertFalse(a.synced());

        // a fresh publish (anyone's, at the home) brings the copy back, with the home's record
        vm.warp(late + 1 hours);
        deliver(fresh);
        assertTrue(a.synced());
        assertFalse(a.checkOwnerSignature(d, signWallet(WALLET_A, d)), "removed, as at the home");
        assertEq(a.withdrawalAddress(), DEST2);
        vm.prank(TRANSFER);
        a.withdraw(address(0), 1 ether);
        assertEq(DEST2.balance, 1 ether);
    }

    /// M1's renewal: the same version published later renews the copy; one published no later than the
    /// record held, or an older version, is ignored.
    function test_audit_theSameRecordPublishedLaterRenewsTheCopy() public {
        setWithdrawalNow(a, PASSKEY_A, DEST);
        uint256 t0 = vm.getBlockTimestamp();
        rec(a).publish(19);
        bytes memory first = mt.body();
        vm.warp(t0 + 20 days);
        rec(a).publish(19);
        bytes memory renewal = mt.body();

        toCopyAtGenesis();
        vm.warp(t0);
        deliver(first);
        assertEq(a.recordPublishedAt(), t0);
        vm.warp(t0 + 25 days);
        deliver(renewal);
        assertEq(a.recordPublishedAt(), t0 + 20 days, "renewed, its version unchanged");
        vm.warp(t0 + 45 days);
        assertTrue(a.synced(), "30 days from the renewal");
        vm.recordLogs();
        deliver(first);
        assertEq(vm.getRecordedLogs().length, 1, "an older publish of the same version: RecordIgnored");
        assertEq(a.recordPublishedAt(), t0 + 20 days);
        vm.warp(t0 + 50 days + 1);
        assertFalse(a.synced());
    }

    /// M2's support: `isCredentialId` answers as `isCredential`, by the credential's id.
    function test_audit_isCredentialIdAnswersAsIsCredential() public {
        assertTrue(a.isCredentialId(a.credentialId(wallet(WALLET_A))));
        assertTrue(a.isCredentialId(a.credentialId(passkey(PASSKEY_A))));
        assertFalse(a.isCredentialId(a.credentialId(wallet(WALLET_B))));
        toCopyAtGenesis();
        assertFalse(a.isCredentialId(a.credentialId(wallet(WALLET_A))), "an unsynced copy trusts none");
    }
}

contract PartnerAuditMoneyTest is MoneyTest {
    /// M3: a stolen transfer key's round trips. Each burn pays Circle up to 10 bp; the day's fees together
    /// are capped at 10 bp of the chain's USDC at the day's first fee-paying burn: the second round trip of
    /// the day is refused, the next day's first goes. Zero-fee burns are never counted.
    function test_audit_repeatedBurnsAreBudgetedPerDay() public {
        MockTokenMessenger m = MockTokenMessenger(TM);
        m.setMinFee(true, 10_000); // Circle's minimum at 10 bp, the cap itself
        uint256 start = usdc(address(a));
        uint256 paid;
        for (uint256 i; i < 10; ++i) {
            uint256 amt = usdc(address(a));
            vm.prank(TRANSFER);
            if (i > 0) vm.expectRevert(DepositAccountState.BurnFeeTooHigh.selector);
            a.convertBurn(amt, 2);
            if (i > 0) continue;
            paid += m.maxFee();
            MockToken(USDC).mint(address(a), amt - m.maxFee()); // the mint back, less Circle's fee
        }
        assertEq(paid, start / 1_000, "one day: 10 bp of the balance, once");
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 amt = usdc(address(a));
        vm.prank(TRANSFER);
        a.convertBurn(amt, 2);
        assertEq(m.maxFee(), amt / 1_000, "the next day, one more");
        // zero-fee burns: never refused by the budget
        m.setMinFee(false, 0);
        MockToken(USDC).mint(address(a), 1_000e6);
        for (uint256 i; i < 3; ++i) {
            vm.prank(TRANSFER);
            a.convertBurn(100e6, 2);
        }
    }

    /// M3: within a day, smaller burns share the budget until it is spent.
    function test_audit_smallBurnsShareTheDaysBudget() public {
        MockTokenMessenger m = MockTokenMessenger(TM);
        m.setMinFee(true, 10_000);
        // 1,000 USDC here: the day's budget is 1 USDC; each 250 USDC burn pays 0.25
        for (uint256 i; i < 4; ++i) {
            vm.prank(TRANSFER);
            a.convertBurn(250e6, 2);
            MockToken(USDC).mint(address(a), 250e6 - m.maxFee());
        }
        vm.prank(TRANSFER);
        vm.expectRevert(DepositAccountState.BurnFeeTooHigh.selector);
        a.convertBurn(10e6, 2);
    }

    /// M3 (the review's P2-2): the cap follows the day's highest balance, so a large deposit arriving after
    /// a small burn still converts the same day; a round trip never raises it.
    function test_audit_aLaterLargeDepositStillBurnsTheSameDay() public {
        MockTokenMessenger m = MockTokenMessenger(TM);
        m.setMinFee(true, 10_000);
        vm.prank(TRANSFER);
        a.convertBurn(1_000e6, 2); // the whole balance: its 1 USDC fee is the day's cap so far
        MockToken(USDC).mint(address(a), 100_000e6); // a large deposit later that day
        vm.prank(TRANSFER);
        a.convertBurn(99_000e6, 2); // the day's cap is now 100 USDC (10 bp of 100,000), 1 already paid
        assertEq(m.maxFee(), 99e6);
        MockToken(USDC).mint(address(a), 99_000e6 - 99e6); // the round trip back
        vm.prank(TRANSFER);
        vm.expectRevert(DepositAccountState.BurnFeeTooHigh.selector);
        a.convertBurn(10_000e6, 2);
    }
}
