// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {DepositAccount} from "../../src/DepositAccount.sol";
import {DepositAccountRecord} from "../../src/DepositAccountRecord.sol";

/*
 * A TEST version 2 of the deposit contract (owner-upgrades-design.md §9): version 1 plus one field
 * appended to the layout (after every version-1 field, in both the main contract and its module) and
 * one new function. Never deployed. `DepositAccountV3` and `V4` are the same code numbered 3 and 4,
 * for the list's order, a copy ahead of its home, and successions.
 */
contract DepositAccountV2 is DepositAccount {
    /// Appended: zero after the upgrade, as I8 asks of every new field.
    uint256 public extra;

    constructor(address factory_, address module_, bytes32 moduleCodeHash)
        DepositAccount(factory_, module_, moduleCodeHash)
    {}

    function CODE_VERSION() public pure virtual override returns (uint256) {
        return 2;
    }

    /// The new function: anyone bumps the new field.
    function bump() external {
        ++extra;
    }
}

contract DepositAccountRecordV2 is DepositAccountRecord {
    uint256 internal extra;

    constructor(address factory_) DepositAccountRecord(factory_) {}

    function CODE_VERSION() public pure virtual override returns (uint256) {
        return 2;
    }
}

contract DepositAccountV3 is DepositAccountV2 {
    constructor(address factory_, address module_, bytes32 moduleCodeHash)
        DepositAccountV2(factory_, module_, moduleCodeHash)
    {}

    function CODE_VERSION() public pure override returns (uint256) {
        return 3;
    }
}

contract DepositAccountRecordV3 is DepositAccountRecordV2 {
    constructor(address factory_) DepositAccountRecordV2(factory_) {}

    function CODE_VERSION() public pure override returns (uint256) {
        return 3;
    }
}

contract DepositAccountV4 is DepositAccountV2 {
    constructor(address factory_, address module_, bytes32 moduleCodeHash)
        DepositAccountV2(factory_, module_, moduleCodeHash)
    {}

    function CODE_VERSION() public pure override returns (uint256) {
        return 4;
    }
}

contract DepositAccountRecordV4 is DepositAccountRecordV2 {
    constructor(address factory_) DepositAccountRecordV2(factory_) {}

    function CODE_VERSION() public pure override returns (uint256) {
        return 4;
    }
}
