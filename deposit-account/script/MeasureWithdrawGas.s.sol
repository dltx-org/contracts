// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {Credential, DepositAccount, Withdrawal} from "../src/DepositAccount.sol";
import {DepositFactory} from "../src/DepositFactory.sol";
import {Helpers} from "../test/Helpers.sol";

/*
 * Measures a first owner-signed withdrawal (`withdrawSigned`, the path api2 quotes) on a LOCAL anvil
 * fork, never a real network: `script/measure-withdraw-gas.sh` starts one `anvil --fork-url` per
 * deposit chain and drives the two phases below, sending every transaction from anvil's unlocked
 * accounts and impersonated addresses (no key is read). The receipts' `gasUsed` is the measurement.
 *
 *   prepare()         the factory through the chain's deterministic deployer (recovery: the relayer, so
 *                     it can name a fee recipient), one account owned by a wallet and one by a passkey;
 *                     at the home a signed withdrawal address each (24 h hold: the driver warps), at a
 *                     copy the home's record delivered as Circle's transmitter (impersonated).
 *   withdraw(kind)    0: the wallet's account, 1: the passkey's; 100 of 1,000 USDC with a 0.5 USDC fee,
 *                     both recipients fresh (zero balances), the signer's first local nonce, and at the
 *                     home the 24-hour withdrawal address settling in the same call. The worst first
 *                     withdrawal a holding sees, short of the refund a full withdrawal earns.
 *   burn(domain)      step 11e1, any chain: the wallet's account burns 100 of its USDC by the chain's
 *                     real CCTP V2 messenger to `domain`, minted to itself there (`convertBurn`, the
 *                     transfer key's: the relayer, named in `prepare`). The account already deployed.
 */
contract MeasureWithdrawGas is Helpers {
    /// anvil's first unlocked account: deployer, recovery and relayer
    address constant RELAYER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address constant TRANSMITTER = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;
    bytes32 constant USER_W = keccak256("dltx.gas.user.wallet");
    bytes32 constant USER_P = keccak256("dltx.gas.user.passkey");

    function feeTo() internal pure returns (address) {
        return address(uint160(uint256(keccak256("dltx.gas.fee-recipient"))));
    }

    function destOf(uint256 kind) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("dltx.gas.withdrawal-address", kind)))));
    }

    function keyOf(uint256 kind) internal pure returns (uint256) {
        return kind == 0 ? WALLET_A : PASSKEY_A;
    }

    function factory() internal pure returns (DepositFactory) {
        bytes memory init = abi.encodePacked(type(DepositFactory).creationCode, abi.encode(RELAYER));
        return DepositFactory(
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), DEPLOYER, FACTORY_SALT, keccak256(init))))))
        );
    }

    function accountOf(uint256 kind) public view returns (DepositAccount) {
        return DepositAccount(factory().addressOf(kind == 0 ? USER_W : USER_P, one(credOf(keyOf(kind)))));
    }

    function prepare() external {
        DepositFactory f = factory();
        vm.startBroadcast(RELAYER);
        (bool ok,) = DEPLOYER.call(abi.encodePacked(FACTORY_SALT, type(DepositFactory).creationCode, abi.encode(RELAYER)));
        require(ok && address(f).code.length > 0, "factory deployment failed");
        f.setFeeRecipient(feeTo());
        f.setTransferKey(RELAYER); // step 11e1, any chain: `burn` is the transfer key's
        for (uint256 kind; kind < 2; ++kind) {
            DepositAccount a = DepositAccount(f.deploy(kind == 0 ? USER_W : USER_P, one(credOf(keyOf(kind)))));
            if (a.isHome()) setWithdrawal(a, keyOf(kind), destOf(kind));
        }
        vm.stopBroadcast();
        if (block.chainid == 42161) return;
        vm.startBroadcast(TRANSMITTER);
        for (uint256 kind; kind < 2; ++kind) {
            DepositAccount a = accountOf(kind);
            // published an hour ahead: never before the copy's deployment, whichever block it lands in
            bytes memory body = abi.encode(
                a.RECORD_TAG(), uint64(1), uint64(vm.getBlockTimestamp() + 1 hours), destOf(kind), one(credOf(keyOf(kind)))
            );
            a.handleReceiveFinalizedMessage(3, bytes32(uint256(uint160(address(a)))), 2000, body);
        }
        vm.stopBroadcast();
    }

    function withdraw(uint256 kind, address token) external {
        DepositAccount a = accountOf(kind);
        Withdrawal memory w = withdrawal(a, token, 100e6, 1e6);
        bytes memory sig = signWithdrawal(a, keyOf(kind), w);
        require(w.to == destOf(kind), "no withdrawal address in effect");
        vm.broadcast(RELAYER);
        a.withdrawSigned(w, 0.5e6, sig);
    }

    function burn(uint32 domain) external {
        DepositAccount a = accountOf(0);
        vm.broadcast(RELAYER);
        a.convertBurn(100e6, domain);
    }
}
