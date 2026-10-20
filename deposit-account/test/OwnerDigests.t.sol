// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {console} from "forge-std/console.sol";
import {DepositAccount, StrategyGrant} from "../src/DepositAccount.sol";
import {DepositFactory} from "../src/DepositFactory.sol";
import {FixtureVaultFactory, Helpers} from "./Helpers.sol";

/*
 * `AuthoriseStrategy`, AS A DIGEST VECTOR FOR THE TYPESCRIPT SIDE (step 11e3 §8.4, slice 1).
 *
 * `@engine/owner` computes the digest from its own copy of the type string and the owner domain;
 * `engine/owner/tests/vault-messages.test.ts` pins the literal below. Two halves, so neither side drifts:
 *   - `test_digestVector`: fixed inputs through the account's OWN `hashTypedData` and its public
 *     `AUTHORISE_STRATEGY_TYPEHASH`, the account's code etched at a fixed address (the domain's
 *     `verifyingContract`), so the factory's salt or bytecode moves nothing here.
 *     `forge test --match-test test_digestVector -vv` prints it;
 *   - `test_accountAcceptsTheDigest`: `authoriseStrategy` accepts a wallet's and a passkey's signature over
 *     the digest computed by the SAME helper, and refuses one over another chain's: the helper is the
 *     account's own encoding of the struct.
 */
contract OwnerDigestsTest is Helpers {
    address constant ACCOUNT_V = 0x00000000000000000000000000000000000D1D1D;
    address constant FACTORY_V = 0x3333333333333333333333333333333333333333;
    bytes32 constant STRATEGY_V = 0x000000000000000000000000000000000192f1a2b3c47d8e9f00112233445566;
    bytes32 constant CONFIG_V = 0xcccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc;

    DepositFactory f;
    DepositAccount a;

    function setUp() public {
        vm.chainId(42161);
        f = deployFactory();
        a = deployTwo(f, ALICE, WALLET_A, passkey(PASSKEY_A));
    }

    /// The struct hash `authoriseStrategy` signs, through the account's own domain.
    function _authorise(DepositAccount acct, uint256 chainId, StrategyGrant memory g) internal view returns (bytes32) {
        return acct.hashTypedData(
            keccak256(
                abi.encode(
                    acct.AUTHORISE_STRATEGY_TYPEHASH(),
                    chainId,
                    g.vaultFactory,
                    g.domain,
                    g.strategyId,
                    g.configHash,
                    g.allowance,
                    g.nonce,
                    g.deadline
                )
            )
        );
    }

    function test_digestVector() public {
        vm.etch(ACCOUNT_V, address(a).code);
        DepositAccount at = DepositAccount(ACCOUNT_V);
        StrategyGrant memory g = StrategyGrant(FACTORY_V, 3, STRATEGY_V, CONFIG_V, 250_000_000, 4, 1_800_000_000);
        bytes32 digest = _authorise(at, 42161, g);
        console.log("domainSeparator");
        console.logBytes32(at.domainSeparator());
        console.log("AuthoriseStrategy");
        console.logBytes32(digest);
        assertEq(at.domainSeparator(), 0x4e9a663853527e9c96e06f2735c7a91b7b6c128aaea3d88b2e611cd4765f3217);
        assertEq(digest, 0x0cd9bd678d9654c88b8689384eae6428242b1ef8ad8946d07a1d6aaa8268c96b, "AuthoriseStrategy");
    }

    function test_accountAcceptsTheDigest() public {
        FixtureVaultFactory vf = new FixtureVaultFactory();
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        StrategyGrant memory g = StrategyGrant(
            address(vf), 3, STRATEGY_V, CONFIG_V, 250_000_000, a.localNonceOf(credOf(WALLET_A)), deadline
        );
        // another chain's digest is refused: the chain is in the message, not the domain
        bytes memory otherChain = sign(WALLET_A, _authorise(a, 1, g));
        vm.expectRevert();
        a.authoriseStrategy(g, otherChain);
        a.authoriseStrategy(g, sign(WALLET_A, _authorise(a, block.chainid, g)));
        assertEq(a.localNonceOf(credOf(WALLET_A)), g.nonce + 1);
        // a passkey signs the same digest as its WebAuthn challenge
        g.nonce = a.localNonceOf(credOf(PASSKEY_A));
        a.authoriseStrategy(g, sign(PASSKEY_A, _authorise(a, block.chainid, g)));
        assertEq(a.localNonceOf(credOf(PASSKEY_A)), g.nonce + 1);
    }
}
