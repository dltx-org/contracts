// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {CombinedReviewMoneyTest, CombinedReviewRecordTest} from "./CombinedReview.t.sol";
import {FundingTest} from "./Funding.t.sol";
import {MoneyTest} from "./Money.t.sol";
import {OwnerRecordTest} from "./OwnerRecord.t.sol";
import {PartnerAuditMoneyTest, PartnerAuditRecordTest} from "./PartnerAudit.t.sol";

/*
 * owner-upgrades-design.md §9: every suite of version 1 passes on an account upgraded to the test
 * version 2 (its main contract and its module both version 2's, one field appended). Each suite's
 * account is moved after its own setUp; the copies its tests deploy later start on the genesis, as a
 * copy does (§3.5). OwnerDigests' vector etches the implementation's code, not an account's: no version
 * of it to run.
 */
contract OwnerRecordOnV2Test is OwnerRecordTest {
    function setUp() public override {
        super.setUp();
        moveToV2(f, a);
    }
}

contract MoneyOnV2Test is MoneyTest {
    function setUp() public override {
        super.setUp();
        moveToV2(f, a);
    }
}

contract FundingOnV2Test is FundingTest {
    function setUp() public override {
        super.setUp();
        moveToV2(f, a);
        ready = vm.snapshotState();
    }
}

contract PartnerAuditRecordOnV2Test is PartnerAuditRecordTest {
    function setUp() public override {
        super.setUp();
        moveToV2(f, a);
    }
}

contract PartnerAuditMoneyOnV2Test is PartnerAuditMoneyTest {
    function setUp() public override {
        super.setUp();
        moveToV2(f, a);
    }
}

contract CombinedReviewRecordOnV2Test is CombinedReviewRecordTest {
    function setUp() public override {
        super.setUp();
        moveToV2(f, a);
    }
}

contract CombinedReviewMoneyOnV2Test is CombinedReviewMoneyTest {
    function setUp() public override {
        super.setUp();
        moveToV2(f, a);
    }
}
