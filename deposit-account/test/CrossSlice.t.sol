// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {Vm} from "forge-std/Test.sol";
import {Credential, DepositAccount} from "../src/DepositAccount.sol";
import {DepositFactory} from "../src/DepositFactory.sol";
import {FixtureVaultFactory, Helpers} from "./Helpers.sol";
import {IStrategyVaultFactory, PairConfig, StrategyVaultFixture} from "./fixtures/StrategyVault.sol";

interface IToken {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

/*
 * Amendment 1's integration tests (§5), on forks (each skipped without its RPC url):
 *   - Arbitrum: slice 2's REAL vault factory (its pinned build, test/fixtures) creates a vault with the
 *     owner's `CreateVault` signature, and the deposit account funds it through the factory's trust and
 *     registration; a configuration slice 2's `_validate` refuses can never be created, so never funded;
 *   - Arbitrum → Ethereum: the home dispatches an authorisation through Circle's real transmitter and
 *     burns USDC to the user's own address on Ethereum by CCTP; the Ethereum copy receives the record
 *     and the authorisation (delivered by impersonating Circle's transmitter), then funds a vault of
 *     the FIXTURE factory (slice 2's real factory refuses Ethereum, `WrongChain`; the test moves to a
 *     real factory once an Ethereum template exists).
 */
contract CrossSliceTest is Helpers {
    address constant MT = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;
    address constant ARB_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant ETH_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    bytes32 constant MESSAGE_SENT = keccak256("MessageSent(bytes)");
    bytes32 constant FIXTURE_SALT = keccak256("dltx.fixture-vault-factory");
    bytes32 constant STRATEGY = keccak256("strategy A");

    function fork(string memory env) internal returns (bool) {
        string memory url = vm.envOr(env, string(""));
        if (bytes(url).length == 0) return false;
        vm.createSelectFork(url);
        return true;
    }

    /// The genesis: one credential (amendment 2d, decision 76).
    function owners() internal pure returns (Credential[] memory) {
        return one(passkey(PASSKEY_A));
    }

    function home() internal returns (DepositFactory f, DepositAccount a) {
        f = deployFactory();
        vm.prank(RECOVERY);
        f.setTransferKey(TRANSFER);
        a = DepositAccount(f.deploy(ALICE, owners()));
    }

    /// The build in test/fixtures is slice 2's pinned one (no fork).
    function test_theFixtureIsSlice2sPinnedBuild() public view {
        bytes memory code = vm.parseBytes(vm.readFile(StrategyVaultFixture.BUILD));
        assertEq(keccak256(code), StrategyVaultFixture.PINNED_CREATION_CODE_HASH);
    }

    function deployStrategyVaultFactory() internal returns (IStrategyVaultFactory) {
        bytes memory code = vm.parseBytes(vm.readFile(StrategyVaultFixture.BUILD));
        (bool ok, bytes memory ret) =
            DEPLOYER.call(abi.encodePacked(StrategyVaultFixture.FACTORY_SALT, code, abi.encode(RECOVERY)));
        require(ok && ret.length == 20, "vault factory deployment failed");
        return IStrategyVaultFactory(address(bytes20(ret)));
    }

    function createSig(DepositAccount a, bytes32 strategyId, bytes32 configHash, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash =
            keccak256(abi.encode(StrategyVaultFixture.CREATE_VAULT_TYPEHASH, strategyId, configHash, deadline));
        return signPasskey(PASSKEY_A, a.hashTypedData(structHash));
    }

    function test_arbitrum_slice2sRealFactoryCreatesAndTheAccountFunds() public {
        if (!fork("ARBITRUM_RPC_URL")) return vm.skip(true);
        (, DepositAccount a) = home();
        IStrategyVaultFactory vf = deployStrategyVaultFactory();
        (address vault, bytes32 configHash) = createReal(a, vf);
        (address badVault, bytes32 badHash) = refusedReal(a, vf);

        setWithdrawalNow(a, PASSKEY_A, DEST);
        uint256 id = authorise(a, PASSKEY_A, address(vf), 3, STRATEGY, configHash, 500e6);
        uint256 badId = authorise(a, PASSKEY_A, address(vf), 3, STRATEGY, badHash, 500e6);
        deal(ARB_USDC, address(a), 600e6);
        vm.prank(TRANSFER);
        vm.expectRevert(DepositAccount.NotTrusted.selector);
        a.fund(address(vf), vault, 500e6); // the factory's first 24 hours
        vm.warp(dueOf(a, address(vf), 3));
        a.applyAuthorisation(id);
        a.applyAuthorisation(badId);
        vm.prank(TRANSFER);
        a.fund(address(vf), vault, 500e6);
        assertEq(IToken(ARB_USDC).balanceOf(vault), 500e6, "the real vault funded");
        assertEq(badVault.code.length, 0);
        vm.prank(TRANSFER);
        vm.expectRevert(DepositAccount.NotOwnVault.selector);
        a.fund(address(vf), badVault, 1e6);
    }

    /// The real factory creates the long half with the owner's CreateVault signature, checked through
    /// the account, and registers it to the account.
    function createReal(DepositAccount a, IStrategyVaultFactory vf) internal returns (address vault, bytes32 configHash) {
        PairConfig memory cfg = StrategyVaultFixture.config(address(vf));
        address longVault;
        (longVault,, configHash) = vf.pairAddresses(STRATEGY, address(a), cfg);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        vault = vf.create(STRATEGY, address(a), cfg, deadline, createSig(a, STRATEGY, configHash, deadline));
        assertEq(vault, longVault);
        (address owner, bytes32 sid, bytes32 ch) = vf.authorisedFor(vault);
        assertEq(owner, address(a));
        assertEq(sid, STRATEGY);
        assertEq(ch, configHash);
    }

    /// A configuration slice 2's `_validate` refuses (a health floor below its 1.05): never created.
    function refusedReal(DepositAccount a, IStrategyVaultFactory vf) internal returns (address badVault, bytes32 badHash) {
        PairConfig memory bad = StrategyVaultFixture.config(address(vf));
        bad.long.healthFloor = 1e18;
        (badVault,, badHash) = vf.pairAddresses(STRATEGY, address(a), bad);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory badSig = createSig(a, STRATEGY, badHash, deadline);
        vm.expectRevert(bytes4(keccak256("BadConfig()")));
        vf.create(STRATEGY, address(a), bad, deadline, badSig);
    }

    function deployFixtureFactory() internal returns (FixtureVaultFactory) {
        (bool ok, bytes memory ret) = DEPLOYER.call(abi.encodePacked(FIXTURE_SALT, type(FixtureVaultFactory).creationCode));
        require(ok && ret.length == 20, "fixture factory deployment failed");
        return FixtureVaultFactory(address(bytes20(ret)));
    }

    function sentBody(Vm.Log[] memory logs) internal pure returns (bytes memory body) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == MT && logs[i].topics[0] == MESSAGE_SENT) {
                bytes memory m = abi.decode(logs[i].data, (bytes));
                body = new bytes(m.length - 148); // CCTP V2's header is 148 bytes
                for (uint256 j; j < body.length; ++j) body[j] = m[148 + j];
                return body;
            }
        }
        revert("no MessageSent");
    }

    function test_ethereum_aDispatchedAuthorisationFundsAFixtureVault() public {
        if (!fork("ARBITRUM_RPC_URL")) return vm.skip(true);
        (, DepositAccount a) = home();
        address fixture = address(deployFixtureFactory()); // its address, the same on Ethereum
        bytes32 config = keccak256("an Ethereum configuration");
        setWithdrawalNow(a, PASSKEY_A, DEST);
        uint256 id = authorise(a, PASSKEY_A, fixture, 0, STRATEGY, config, 300e6);
        vm.warp(dueOf(a, fixture, 0));
        vm.recordLogs();
        a.dispatchAuthorisation(id);
        bytes memory auth = sentBody(vm.getRecordedLogs());
        vm.recordLogs();
        a.publish(0);
        bytes memory record = sentBody(vm.getRecordedLogs());
        // the money: a real CCTP burn to the user's own address on Ethereum
        deal(ARB_USDC, address(a), 300e6);
        uint256 supply = IToken(ARB_USDC).totalSupply();
        vm.prank(TRANSFER);
        a.convertBurn(300e6, 0);
        assertEq(supply - IToken(ARB_USDC).totalSupply(), 300e6);

        if (!fork("MAINNET_RPC_URL")) return;
        (, DepositAccount copy) = home();
        assertEq(address(copy), address(a));
        FixtureVaultFactory ethFactory = deployFixtureFactory();
        assertEq(address(ethFactory), fixture);
        bytes32 self = bytes32(uint256(uint160(address(copy))));
        vm.prank(MT);
        copy.handleReceiveFinalizedMessage(3, self, 2000, record);
        assertTrue(copy.synced());
        vm.prank(MT);
        copy.handleReceiveFinalizedMessage(3, self, 2000, auth);
        assertTrue(copy.isTrusted(fixture, 0));
        assertEq(copy.allowanceOf(fixture, STRATEGY, config), 300e6);
        deal(ETH_USDC, address(copy), 300e6); // Circle's mint lands at the user's own address
        address vault = ethFactory.create(STRATEGY, address(copy), config);
        vm.prank(TRANSFER);
        copy.fund(fixture, vault, 300e6);
        assertEq(IToken(ETH_USDC).balanceOf(vault), 300e6);
        // a redispatch adds nothing
        vm.prank(MT);
        copy.handleReceiveFinalizedMessage(3, self, 2000, auth);
        assertEq(copy.allowanceOf(fixture, STRATEGY, config), 0);
    }
}
