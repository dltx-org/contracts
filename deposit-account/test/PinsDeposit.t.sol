// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {console} from "forge-std/Test.sol";
import {Credential, DepositAccount} from "../src/DepositAccount.sol";
import {DepositFactory} from "../src/DepositFactory.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {Helpers} from "./Helpers.sol";

/*
 * The deposit project's PINS as this build computes them, one `PIN <name> <value>` line each, for
 * `scripts/repin-v1.mjs` (the re-pin cascade, deploy-factories.md §5c: the vault's factory is
 * `PINNED_VAULT_FACTORY`, in the deposit contract's bytes, so in the deposit factory's creation code and
 * every address below). Skipped unless PRINT_PINS=1.
 *
 *   PRINT_PINS=1 forge test --match-contract PinsDeposit -vv
 */
contract PinsDepositTest is Helpers {
    function test_printPins() public {
        if (!vm.envOr("PRINT_PINS", false)) {
            vm.skip(true);
            return;
        }
        _b("PINNED_CREATION_CODE_HASH", keccak256(type(DepositFactory).creationCode));
        DepositFactory f = deployFactory(); // the test vectors' RECOVERY (0xBEEF02)
        Credential[] memory owners = two(wallet(WALLET_A), passkey(PASSKEY_A));
        _a("FACTORY_VECTOR", address(f));
        _a("GENESIS_VECTOR", f.genesis());
        _a("MODULE_VECTOR", DepositAccount(f.genesis()).module());
        _b("SALT_VECTOR", f.saltOf(ALICE, owners));
        _a("ACCOUNT_VECTOR", f.addressOf(ALICE, owners));
        // the production factory, for the deploy script's RECOVERY (a placeholder until the hardware wallet)
        Deploy d = new Deploy();
        _a("DEPOSIT_RECOVERY", d.RECOVERY());
        _a("DEPOSIT_FACTORY", d.factoryOf(d.RECOVERY()));
    }

    function _a(string memory n, address v) internal pure {
        console.log(string.concat("PIN ", n, " ", vm.toString(v)));
    }

    function _b(string memory n, bytes32 v) internal pure {
        console.log(string.concat("PIN ", n, " ", vm.toString(v)));
    }
}
