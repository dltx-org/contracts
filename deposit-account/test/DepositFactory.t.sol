// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {Credential, DepositAccount} from "../src/DepositAccount.sol";
import {DepositAccountState} from "../src/DepositAccountState.sol";
import {DepositFactory} from "../src/DepositFactory.sol";
import {ProxyInitCode} from "../src/ProxyInitCode.sol";
import {ContractWallet, Helpers} from "./Helpers.sol";
import {Deploy} from "../script/Deploy.s.sol";

/*
 * The factory: the pinned build, the addresses, permissionless deployment from the first owner set,
 * the transfer key and its check-in, the fee recipient, recovery's handover. No fork.
 */
contract DepositFactoryTest is Helpers {
    /// 🔒 THE BUILD THAT EVERY ADDRESS HANGS ON. The factory's address is the hash of its creation
    /// code (and its two constructor arguments); once it is deployed anywhere, this must never change,
    /// or a later chain's factory lands elsewhere and a user's money sent there is out of reach.
    /// Update it only before the first deployment, deliberately
    /// (`forge inspect DepositFactory bytecode | cast keccak`), and in script/Deploy.s.sol with it.
    bytes32 constant PINNED_CREATION_CODE_HASH = 0x798060600150566aab91bf10516dc49b93b5b3c82979c0653d0cf52f6b12b807;
    // the vectors (RECOVERY = 0xBEEF02, Helpers'), for engine/evm and web: `scripts/repin-v1.mjs` re-pins them
    address constant FACTORY_VECTOR = 0xc53D77846d5AeE4f5761c2bf34E269c5463AdBE3;
    address constant GENESIS_VECTOR = 0xDeE00f661aF8C8f42F13644E54B8330C6FD37fce;
    address constant MODULE_VECTOR = 0x49155C0126445588a41C0B20a90d4758c55eE1dA;
    bytes32 constant SALT_VECTOR = 0xb11d2599ac7f6f79b1b23ec7b287342dc21e2257c2a12bb00798b95d1a7c305e;
    address constant ACCOUNT_VECTOR = 0x48803fc445EF5Be9B4193F0dFA167Bf84D9c3469;
    /// The production factory, for the deploy script's RECOVERY (a PLACEHOLDER until the hardware wallet).
    address constant DEPOSIT_FACTORY = 0x3a715d1072A42c1BD65aB0c9755DDFB3Bb3E39BF;

    DepositFactory f;

    function setUp() public {
        f = deployFactory();
    }

    // ── the build and the addresses ──────────────────────────────────────────────────────────

    function test_theBuildIsThePinnedOne() public pure {
        assertEq(keccak256(type(DepositFactory).creationCode), PINNED_CREATION_CODE_HASH, "the factory's bytecode moved");
    }

    /// Vectors for engine/evm and web (slices 1b, 1c): the factory through the deterministic deployer
    /// for RECOVERY (its only constructor argument, amendment 1), its genesis (version 1, the factory's
    /// second CREATE, after its module), and an account
    /// for a fixed owner set. Two credentials: the CREATE2 formula and the set's order in the salt, which
    /// `addressOf` computes for any set, though only a one-credential genesis deploys (decision 76).
    function test_addressVectors() public view {
        Credential[] memory owners = two(wallet(WALLET_A), passkey(PASSKEY_A));
        assertEq(address(f), predictedFactory(RECOVERY), "factory");
        assertEq(f.saltOf(ALICE, owners), keccak256(abi.encode(ALICE, owners)), "salt");
        assertEq(f.addressOf(ALICE, owners), predictedProxy(address(f), f.saltOf(ALICE, owners)));
        // the literal vectors, for the TypeScript side to assert the same (the build pinned above)
        assertEq(address(f), FACTORY_VECTOR, "factory vector");
        assertEq(f.genesis(), GENESIS_VECTOR, "genesis vector");
        assertEq(DepositAccount(f.genesis()).module(), MODULE_VECTOR, "module vector");
        assertEq(ProxyInitCode.HASH, 0x6f7b25ec6a5059170168f7c23327b6f7e572f9cdcbe26af04cf747b6542bbfc4, "proxy init-code hash");
        assertEq(f.saltOf(ALICE, owners), SALT_VECTOR, "salt vector");
        assertEq(f.addressOf(ALICE, owners), ACCOUNT_VECTOR, "account vector");
    }

    /// The deploy script's factory, for its RECOVERY: the address every deposit chain gets.
    function test_productionFactory() public {
        Deploy d = new Deploy();
        assertEq(d.factoryOf(d.RECOVERY()), predictedFactory(d.RECOVERY()));
        assertEq(d.factoryOf(d.RECOVERY()), DEPOSIT_FACTORY, "the production factory");
    }

    function predictedFactory(address recovery) internal pure returns (address) {
        bytes memory init = abi.encodePacked(type(DepositFactory).creationCode, abi.encode(recovery));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), DEPLOYER, FACTORY_SALT, keccak256(init))))));
    }

    /// The proxy's address: CREATE2 of its one init code, whatever implementation it runs (§3.1).
    function predictedProxy(address factory, bytes32 salt) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), factory, salt, ProxyInitCode.HASH)))));
    }

    /// Amendment 1: no vault factory in the deposit factory's build or address; recovery is all.
    function test_theFactoryNamesNoVaultFactory() public view {
        bytes memory init = abi.encodePacked(type(DepositFactory).creationCode, abi.encode(RECOVERY));
        assertEq(address(f), address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), DEPLOYER, FACTORY_SALT, keccak256(init)))))));
        (bool ok,) = address(f).staticcall(abi.encodeWithSignature("vaultFactory()"));
        assertFalse(ok, "no vaultFactory()");
    }

    function testFuzz_addressOfIsTheCreate2Formula(bytes32 user) public view {
        Credential[] memory owners = one(passkey(PASSKEY_A));
        assertEq(f.addressOf(user, owners), predictedProxy(address(f), keccak256(abi.encode(user, owners))));
    }

    function test_anotherOwnerSetIsAnotherAddress() public view {
        address a = f.addressOf(ALICE, one(passkey(PASSKEY_A)));
        assertTrue(a != f.addressOf(ALICE, one(passkey(PASSKEY_B))), "another key");
        assertTrue(a != f.addressOf(ALICE, two(passkey(PASSKEY_A), wallet(WALLET_A))), "another set");
        assertTrue(
            f.addressOf(ALICE, two(passkey(PASSKEY_A), wallet(WALLET_A)))
                != f.addressOf(ALICE, two(wallet(WALLET_A), passkey(PASSKEY_A))),
            "another order"
        );
        assertTrue(a != f.addressOf(bytes32(uint256(ALICE) + 1), one(passkey(PASSKEY_A))), "another user");
    }

    function test_anyoneDeploysWithTheUsersOwnSet() public {
        Credential[] memory owners = one(passkey(PASSKEY_A));
        address predicted = f.addressOf(ALICE, owners);
        assertEq(predicted.code.length, 0);
        vm.prank(STRANGER);
        address made = f.deploy(ALICE, owners);
        assertEq(made, predicted);
        DepositAccount a = DepositAccount(made);
        Credential[] memory got = a.credentials();
        assertEq(got.length, 1);
        assertEq(a.credentialId(got[0]), a.credentialId(owners[0]));
        assertEq(a.version(), 0);
        assertEq(a.withdrawalAddress(), address(0));
        // a second deploy returns the same account and changes nothing
        assertEq(f.deploy(ALICE, owners), made);
    }

    function test_onlyTheFactoryInitialisesAndOnlyOnce() public {
        DepositAccount made = DepositAccount(f.deploy(ALICE, one(passkey(PASSKEY_A))));
        Credential[] memory other = one(wallet(WALLET_B));
        DepositAccount impl = DepositAccount(f.genesis());
        vm.prank(STRANGER);
        vm.expectRevert(DepositAccountState.NotFactory.selector);
        made.initialize(other);
        vm.prank(address(f));
        vm.expectRevert(DepositAccountState.AlreadyInitialised.selector);
        made.initialize(other);
        // the implementation is never an account
        vm.prank(address(f));
        vm.expectRevert(DepositAccountState.AlreadyInitialised.selector);
        impl.initialize(other);
    }

    /// Amendment 2d, decision 76: a genesis holds exactly one credential. Any other set reverts the
    /// whole deployment, so nothing exists at its address; a second credential is an addition, with its
    /// 24 hours (OwnerRecord.t.sol).
    function test_aGenesisHoldsExactlyOneCredential() public {
        Credential[] memory none = new Credential[](0);
        Credential[] memory pair = two(passkey(PASSKEY_A), wallet(WALLET_A));
        Credential[] memory twice = two(passkey(PASSKEY_A), passkey(PASSKEY_A));
        Credential[] memory four = new Credential[](4);
        for (uint256 i; i < 4; ++i) four[i] = wallet(100 + i);
        Credential[] memory five = new Credential[](5);
        for (uint256 i; i < 5; ++i) five[i] = wallet(100 + i);
        Credential[][5] memory sets = [none, pair, twice, four, five];
        for (uint256 i; i < sets.length; ++i) {
            vm.expectRevert(DepositAccountState.BadOwnerSet.selector);
            f.deploy(ALICE, sets[i]);
            assertEq(f.addressOf(ALICE, sets[i]).code.length, 0, "nothing deployed");
        }
    }

    function test_aBadCredentialIsRefused() public {
        Credential memory offCurve = passkey(PASSKEY_A);
        offCurve.y = bytes32(uint256(offCurve.y) + 1);
        vm.expectRevert(DepositAccountState.BadCredential.selector);
        f.deploy(ALICE, one(offCurve));

        vm.expectRevert(DepositAccountState.BadCredential.selector);
        f.deploy(ALICE, one(Credential(1, bytes32(0), bytes32(0))));
        vm.expectRevert(DepositAccountState.BadCredential.selector);
        f.deploy(ALICE, one(Credential(1, bytes32(uint256(1) << 160), bytes32(0))));
        vm.expectRevert(DepositAccountState.BadCredential.selector);
        f.deploy(ALICE, one(Credential(1, bytes32(uint256(0xA11CE)), bytes32(uint256(1)))));
        vm.expectRevert(DepositAccountState.BadCredential.selector);
        f.deploy(ALICE, one(Credential(3, bytes32(uint256(0xA11CE)), bytes32(0))));
    }

    /// Decision 29: a contract wallet answers EIP-1271 from its own code, which a copy doesn't bring.
    /// Genesis is checked for its shape only: an account is always deployable where money already
    /// waits at its address, whatever code a genesis wallet has on that chain. Such a wallet can never
    /// sign (ECDSA only, no EIP-1271); EOA-only at genesis is enforced off-chain, by an ECDSA signature
    /// from the wallet before an address is shown.
    function test_aGenesisWalletIsCheckedForItsShapeOnly() public {
        vm.chainId(42161);
        ContractWallet cw = new ContractWallet();
        DepositAccount made = DepositAccount(f.deploy(ALICE, one(walletOf(address(cw)))));
        assertTrue(made.isCredential(walletOf(address(cw))));
        bytes32 d = keccak256("x");
        assertFalse(made.checkOwnerSignature(d, abi.encodePacked(uint8(1), new bytes(65))), "it can never sign");
        assertFalse(made.checkOwnerSignature(d, signPasskey(PASSKEY_A, d)), "nor anyone else");
    }

    // ── the transfer key, the check-in, the hatch ────────────────────────────────────────────

    function test_aFreshFactoryHasNoTransferKey() public view {
        assertEq(f.transferKey(), address(0));
        assertEq(f.recovery(), RECOVERY);
        assertEq(f.feeRecipient(), address(0));
        assertEq(f.lastCheckIn(1), vm.getBlockTimestamp());
        assertFalse(f.stopped(1));
    }

    function test_theTransferKeyIsSetByRecoveryAndRotatedByItself() public {
        vm.prank(STRANGER);
        vm.expectRevert(DepositFactory.NotAllowed.selector);
        f.setTransferKey(STRANGER);
        vm.prank(TRANSFER);
        vm.expectRevert(DepositFactory.NotAllowed.selector);
        f.setTransferKey(TRANSFER);
        vm.prank(RECOVERY);
        vm.expectRevert(DepositFactory.ZeroAddress.selector);
        f.setTransferKey(address(0));

        vm.prank(RECOVERY);
        f.setTransferKey(TRANSFER);
        assertEq(f.transferKey(), TRANSFER);
        address next = address(0xBEEF05);
        vm.prank(TRANSFER);
        f.setTransferKey(next);
        assertEq(f.transferKey(), next);
        vm.prank(TRANSFER);
        vm.expectRevert(DepositFactory.NotAllowed.selector);
        f.checkIn(supported());
        vm.prank(RECOVERY);
        f.setTransferKey(TRANSFER); // recovery takes it back
        vm.prank(next);
        vm.expectRevert(DepositFactory.NotAllowed.selector);
        f.setTransferKey(next);
    }

    function test_stoppedAfterSevenDaysWithoutACheckIn() public {
        vm.prank(RECOVERY);
        f.setTransferKey(TRANSFER);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        vm.prank(STRANGER);
        vm.expectRevert(DepositFactory.NotAllowed.selector);
        f.checkIn(supported());
        vm.prank(RECOVERY);
        vm.expectRevert(DepositFactory.NotAllowed.selector);
        f.checkIn(supported());
        vm.prank(TRANSFER);
        f.checkIn(supported());
        assertEq(f.lastCheckIn(1), vm.getBlockTimestamp());
        vm.warp(vm.getBlockTimestamp() + 7 days - 1);
        assertFalse(f.stopped(1));
        vm.warp(vm.getBlockTimestamp() + 1);
        assertTrue(f.stopped(1));
        vm.prank(TRANSFER);
        f.checkIn(supported());
        assertFalse(f.stopped(1), "a check-in closes the hatch again");
    }

    /// Before the first check-in, the clock runs from the factory's deployment: a factory nobody
    /// operates opens its hatch after 7 days, and none opens before.
    function test_beforeTheFirstCheckInTheClockRunsFromDeployment() public {
        assertFalse(f.stopped(1));
        vm.warp(vm.getBlockTimestamp() + 7 days - 1);
        assertFalse(f.stopped(1));
        vm.prank(RECOVERY);
        f.setTransferKey(TRANSFER);
        vm.warp(vm.getBlockTimestamp() + 1);
        assertTrue(f.stopped(1), "setting a key is not a check-in");
        vm.prank(TRANSFER);
        f.checkIn(supported());
        assertFalse(f.stopped(1));
    }

    function test_theFeeRecipientIsRecoverysAlone() public {
        vm.prank(TRANSFER);
        vm.expectRevert(DepositFactory.NotAllowed.selector);
        f.setFeeRecipient(TRANSFER);
        vm.prank(RECOVERY);
        f.setFeeRecipient(FEES);
        assertEq(f.feeRecipient(), FEES);
        vm.prank(RECOVERY);
        f.setFeeRecipient(address(0));
        assertEq(f.feeRecipient(), address(0));
    }

    function test_recoveryChangesInTwoSteps() public {
        address next = address(0xBEEF06);
        vm.prank(TRANSFER);
        vm.expectRevert(DepositFactory.NotAllowed.selector);
        f.proposeRecovery(TRANSFER);
        vm.prank(STRANGER);
        vm.expectRevert(DepositFactory.NotAllowed.selector);
        f.acceptRecovery();

        vm.prank(RECOVERY);
        f.proposeRecovery(next);
        assertEq(f.recovery(), RECOVERY, "a proposal changes nothing yet");
        vm.prank(STRANGER);
        vm.expectRevert(DepositFactory.NotAllowed.selector);
        f.acceptRecovery();
        vm.prank(next);
        f.acceptRecovery();
        assertEq(f.recovery(), next);
        assertEq(f.pendingRecovery(), address(0));
        vm.prank(RECOVERY);
        vm.expectRevert(DepositFactory.NotAllowed.selector);
        f.setTransferKey(TRANSFER);
        vm.prank(next);
        f.setTransferKey(TRANSFER);
    }

    function test_constructorRefusesZeros() public {
        vm.expectRevert(DepositFactory.ZeroAddress.selector);
        new DepositFactory(address(0));
    }
}
