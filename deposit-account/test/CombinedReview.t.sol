// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {DepositAccount} from "../src/DepositAccount.sol";
import {DepositAccountState} from "../src/DepositAccountState.sol";
import {DepositFactory} from "../src/DepositFactory.sol";
import {Helpers, MockToken, MockTokenMessenger} from "./Helpers.sol";
import {OwnerRecordTest} from "./OwnerRecord.t.sol";
import {MoneyTest} from "./Money.t.sol";

/// The combined security review of 2026-10-18, the deposit account's findings: each test PASSES while its
/// gap stands (it asserts the bad outcome); a fix flips it.
contract CombinedReviewRecordTest is OwnerRecordTest {
    /// CR-A1: a credential being removed deploys the account on a chain with no copy and holds a publish
    /// made while it still stood; after the removal, that copy takes the held record as its first.
    function test_CR_A1_thiefDeployedCopyTakesHeldRecordAfterRemoval() public {
        vm.revertToState(copyGenesis);
        vm.chainId(137);
        bytes memory held = abi.encode(
            a.RECORD_TAG(), uint64(1), uint64(vm.getBlockTimestamp()), DEST, two(wallet(WALLET_A), wallet(WALLET_B))
        );
        vm.warp(vm.getBlockTimestamp() + 2 days); // removed at the home; nothing published here since
        vm.prank(MT);
        rec(a).handleReceiveFinalizedMessage(3, self(), 2000, held);
        assertTrue(a.isCredential(wallet(WALLET_B)), "removed at the home, a credential here");
        (uint256 n, uint256 dl, bytes memory sig) = revokeSig(a, WALLET_B, true);
        a.revokeTransfer(n, dl, sig);
        assertTrue(a.transferRevoked(), "the removed credential acts on the copy");
    }
}

contract CombinedReviewMoneyTest is MoneyTest {
    /// CR-A2, fixed by the partner's audit M3: a stolen transfer key burns back and forth; the day's
    /// fees are capped at 10 bp of the balance, so the second fee-paying round trip of the day is refused.
    function test_CR_A2_repeatedBurnsBudgetedPerDay() public {
        MockTokenMessenger m = MockTokenMessenger(TM);
        m.setMinFee(true, 10_000); // Circle's minimum at 10 bp, the cap itself
        MockToken(USDC).mint(address(a), 100e6);
        uint256 amt = usdc(address(a));
        vm.prank(TRANSFER);
        a.convertBurn(amt, 2);
        MockToken(USDC).mint(address(a), amt - m.maxFee()); // the mint back, less Circle's fee
        amt = usdc(address(a));
        vm.prank(TRANSFER);
        vm.expectRevert(DepositAccountState.BurnFeeTooHigh.selector);
        a.convertBurn(amt, 2);
    }
}

contract CombinedReviewFactoryTest is Helpers {
    /// CR-A4 / CR-F1: recovery alone keeps the deposit factory's hatch shut through a key it names.
    function test_CR_A4_recoveryKeepsTheHatchShutThroughAKeyItSets() public {
        DepositFactory f = deployFactory();
        address mine = address(0xBAD);
        for (uint256 i; i < 4; ++i) {
            vm.warp(vm.getBlockTimestamp() + 6 days);
            vm.prank(RECOVERY);
            f.setTransferKey(mine);
            vm.prank(mine);
            f.checkIn(supported());
        }
        assertFalse(f.stopped(1), "24 days with no DLTX transfer key, the hatch shut");
    }

    /// CR-A5: an account's address needs its user's uuid to deploy: the same owner under another uuid is
    /// another account, so an account never deployed anywhere is unreachable without DLTX's database.
    function test_CR_A5_anAccountDeploysOnlyWithItsUuid() public {
        DepositFactory f = deployFactory();
        address acct = f.addressOf(ALICE, one(wallet(WALLET_A)));
        assertTrue(f.deploy(bytes32(uint256(1)), one(wallet(WALLET_A))) != acct, "another uuid, another account");
        assertEq(acct.code.length, 0);
    }
}
