// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {Vm} from "forge-std/Test.sol";
import {Credential, DepositAccount} from "../src/DepositAccount.sol";
import {DepositFactory} from "../src/DepositFactory.sol";
import {Helpers} from "./Helpers.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

/// HyperEVM's TokenMessengerV2: its minimum fee, set by its controller (read 2026-10-14).
interface IMinFeeMessenger {
    function minFeeController() external view returns (address);
    function setMinFee(uint256) external;
    function getMinFeeAmount(uint256) external view returns (uint256);
    function depositForBurn(uint256, uint32, bytes32, address, bytes32, uint256, uint32) external;
}

interface IPool {
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 limit, bytes calldata data)
        external
        returns (int256, int256);
}

/// Swaps on a pool for the test: to read what the market gives, and to move it.
contract PoolUser {
    function swapIn(address pool, address tokenIn, bool zeroForOne, uint256 amount) external returns (uint256 out) {
        (int256 a0, int256 a1) = IPool(pool).swap(
            address(this),
            zeroForOne,
            int256(amount),
            zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341,
            abi.encode(tokenIn)
        );
        out = uint256(-(zeroForOne ? a1 : a0));
    }

    function uniswapV3SwapCallback(int256 d0, int256 d1, bytes calldata data) external {
        IERC20(abi.decode(data, (address))).transfer(msg.sender, uint256(d0 > 0 ? d0 : d1));
    }
}

/*
 * Fork tests against the real chains (spec §13). Each runs when its RPC url is set (test.mjs reads
 * them from apps/api/.env; HyperEVM's defaults to its public RPC) and is skipped otherwise:
 *   - Arbitrum: the canonical deterministic deployer, the P-256 precompile present (gas measured),
 *     Circle's real MessageTransmitterV2 sending a deposit account's record, the USDT0 → USDC swap
 *     on the real 0.01% pool, a real CCTP V2 burn;
 *   - HyperEVM: NO P-256 precompile (the passkey verifies through OpenZeppelin's Solidity fallback,
 *     gas measured), a copy receiving the record Arbitrum's transmitter emitted, delivered by
 *     impersonating the MessageTransmitterV2 (Circle's attesters can't be forged on a fork);
 *   - every chain with a url: the factory, implementation and an account at the same address, and
 *     the build (cancun: MCOPY, PUSH0) running there.
 */
contract ForkTest is Helpers {
    bytes32 constant DEPLOYER_CODEHASH = keccak256(DEPLOYER_RUNTIME);
    address constant MT = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;
    address constant ARB_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant ARB_USDT0 = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
    bytes32 constant MESSAGE_SENT = keccak256("MessageSent(bytes)");

    function fork(string memory env) internal returns (bool) {
        string memory url = vm.envOr(env, string(""));
        if (bytes(url).length == 0) {
            emit log_named_string("skipped, no url", env);
            return false;
        }
        vm.createSelectFork(url);
        return true;
    }

    /// The factory as the operator deploys it: through the chain's own deterministic deployer.
    function deployReal() internal returns (DepositFactory f) {
        assertEq(DEPLOYER.codehash, DEPLOYER_CODEHASH, "not the canonical deterministic deployer");
        uint256 g = gasleft();
        f = deployFactory();
        emit log_named_uint("factory deployment gas", g - gasleft());
        vm.prank(RECOVERY);
        f.setTransferKey(TRANSFER);
    }

    /// The genesis: one credential (amendment 2d, decision 76); WALLET_A joins it as an addition.
    function owners() internal pure returns (Credential[] memory) {
        return one(passkey(PASSKEY_A));
    }

    function precompilePresent() internal view returns (bool) {
        // RIP-7212: (h, r, s, x, y) → 1 for a valid signature; empty where there is no precompile
        bytes32 h = keccak256("p256");
        (bytes32 r, bytes32 s) = vm.signP256(PASSKEY_A, h);
        if (uint256(s) > P256_N / 2) s = bytes32(P256_N - uint256(s));
        (uint256 x, uint256 y) = vm.publicKeyP256(PASSKEY_A);
        (bool ok, bytes memory ret) = address(0x100).staticcall(abi.encode(h, r, s, x, y));
        return ok && ret.length == 32 && abi.decode(ret, (uint256)) == 1;
    }

    function passkeyGas(DepositAccount a) internal view returns (uint256 used) {
        bytes32 d = keccak256("BeginExit");
        bytes memory sig = signPasskey(PASSKEY_A, d);
        uint256 g = gasleft();
        bool ok = a.checkOwnerSignature(d, sig);
        used = g - gasleft();
        require(ok, "the passkey did not verify");
    }

    function walletGas(DepositAccount a) internal view returns (uint256 used) {
        bytes32 d = keccak256("BeginExit");
        bytes memory sig = signWallet(WALLET_A, d);
        uint256 g = gasleft();
        bool ok = a.checkOwnerSignature(d, sig);
        used = g - gasleft();
        require(ok, "the wallet did not verify");
    }

    // ── every chain: the same addresses, the build runs ──────────────────────────────────────

    function test_sameAddressesAndTheBuildRunsOnEveryChain() public {
        string[4] memory envs = ["ARBITRUM_RPC_URL", "HYPEREVM_RPC_URL", "MAINNET_RPC_URL", "BASE_RPC_URL"];
        address factory;
        address account;
        uint256 seen;
        for (uint256 i; i < envs.length; ++i) {
            if (!fork(envs[i])) continue;
            DepositFactory f = deployReal();
            DepositAccount a = DepositAccount(f.deploy(ALICE, owners()));
            if (a.isHome()) addNow(a, PASSKEY_A, wallet(WALLET_A)); // the second credential
            else deliverRecord(a, 1, address(0), two(passkey(PASSKEY_A), wallet(WALLET_A))); // a copy in sync
            if (seen == 0) (factory, account) = (address(f), address(a));
            assertEq(address(f), factory, envs[i]);
            assertEq(address(a), account, envs[i]);
            emit log_named_string("chain", envs[i]);
            emit log_named_uint("  chain id", block.chainid);
            emit log_named_string("  P-256 precompile", precompilePresent() ? "present" : "absent");
            emit log_named_uint("  passkey verification gas", passkeyGas(a));
            emit log_named_uint("  wallet verification gas", walletGas(a));
            ++seen;
        }
        if (seen == 0) vm.skip(true);
    }

    // ── Arbitrum: the home ───────────────────────────────────────────────────────────────────

    function test_arbitrum_thePasskeyUsesThePrecompile() public {
        if (!fork("ARBITRUM_RPC_URL")) return vm.skip(true);
        // Arbitrum has RIP-7212 (eth_call on the chain, 2026-10-14), but forge's default runtime
        // does not simulate it: test.mjs runs this test again with `--hardfork osaka`, whose
        // P256VERIFY (EIP-7951) sits at the same address with the same input and output.
        if (!precompilePresent()) {
            emit log("forge's runtime has no P-256 precompile: run with --hardfork osaka");
            return vm.skip(true);
        }
        DepositFactory f = deployReal();
        uint256 g = gasleft();
        DepositAccount a = DepositAccount(f.deploy(ALICE, owners()));
        emit log_named_uint("account deployment gas (one credential)", g - gasleft());
        assertTrue(a.isHome());
        uint256 used = passkeyGas(a);
        emit log_named_uint("passkey verification gas, with the precompile (EIP-7951's 6,900)", used);
        assertLt(used, 120_000, "the precompile, not the fallback");
    }

    /// The home publishes through Circle's real MessageTransmitterV2; the copy on HyperEVM (if its
    /// url is set) applies exactly the body Circle emitted.
    function test_arbitrum_publishThenAHyperEvmCopyApplies() public {
        if (!fork("ARBITRUM_RPC_URL")) return vm.skip(true);
        DepositFactory f = deployReal();
        DepositAccount a = DepositAccount(f.deploy(ALICE, owners()));
        addNow(a, PASSKEY_A, wallet(WALLET_A)); // the owner's second credential
        setWithdrawal(a, PASSKEY_A, DEST);
        addCredential(a, PASSKEY_A, wallet(WALLET_B));
        proposeRemoval(a, PASSKEY_A, wallet(WALLET_A));
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        assertEq(a.version(), 4, "the second credential, the address, the addition and the removal");

        vm.recordLogs();
        vm.prank(STRANGER);
        a.publish(19);
        bytes memory message = sentMessage(vm.getRecordedLogs());
        bytes32 self = bytes32(uint256(uint160(address(a))));
        // CCTP V2's header: version, source, destination, nonce, sender, recipient, caller,
        // minFinalityThreshold, finalityThresholdExecuted, then the body
        assertEq(uint32(bytes4(slice(message, 4, 8))), 3, "source domain");
        assertEq(uint32(bytes4(slice(message, 8, 12))), 19, "destination domain");
        assertEq(bytes32(slice(message, 44, 76)), self, "sender");
        assertEq(bytes32(slice(message, 76, 108)), self, "recipient");
        assertEq(bytes32(slice(message, 108, 140)), bytes32(0), "anyone relays");
        assertEq(uint32(bytes4(slice(message, 140, 144))), 2000, "finalized");
        bytes memory body = slice(message, 148, message.length);

        if (!fork("HYPEREVM_RPC_URL")) return;
        assertEq(block.chainid, 999);
        assertFalse(precompilePresent(), "HyperEVM has no P-256 precompile");
        DepositFactory hf = deployReal();
        assertEq(address(hf), address(f), "the factory, the same address");
        DepositAccount copy = DepositAccount(hf.deploy(ALICE, owners()));
        assertEq(address(copy), address(a), "the account, the same address");
        assertFalse(copy.isHome());
        assertEq(copy.version(), 0);
        assertFalse(copy.synced(), "a fresh copy trusts no credential");
        bytes32 x = keccak256("x");
        assertFalse(copy.checkOwnerSignature(x, signPasskey(PASSKEY_A, x)));

        vm.prank(MT);
        assertTrue(copy.handleReceiveFinalizedMessage(3, self, 2000, body));
        uint256 used = passkeyGas(copy);
        emit log_named_uint("passkey verification gas, HyperEVM (Solidity fallback)", used);
        assertGt(used, 150_000, "the fallback");
        assertEq(copy.version(), 4);
        assertEq(copy.withdrawalAddress(), DEST);
        assertTrue(copy.isCredential(wallet(WALLET_B)));
        assertFalse(copy.isCredential(wallet(WALLET_A)), "the removal reached the copy");
        bytes32 d = keccak256("x");
        assertTrue(copy.checkOwnerSignature(d, signPasskey(PASSKEY_A, d)));
        // and the copy refuses the owner's change directly
        vm.expectRevert(DepositAccount.NotHome.selector);
        this.setOn(copy, DEST2);
    }

    function setOn(DepositAccount a, address next) external {
        setWithdrawal(a, PASSKEY_A, next);
    }

    function sentMessage(Vm.Log[] memory logs) internal pure returns (bytes memory) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == MT && logs[i].topics[0] == MESSAGE_SENT) return abi.decode(logs[i].data, (bytes));
        }
        revert("no MessageSent");
    }

    function slice(bytes memory b, uint256 from, uint256 to) internal pure returns (bytes memory out) {
        out = new bytes(to - from);
        for (uint256 i; i < out.length; ++i) out[i] = b[from + i];
    }

    /// The real 0.01% pool. What the market gives is read first (a swap in a snapshot): below
    /// 1 USD less the bound, the conversion is refused; at or above it, it runs. Then the market is
    /// moved above the bound (USDC sold into the pool) and the conversion runs on the real pool.
    function test_arbitrum_convertUsdt0OnTheRealPool() public {
        if (!fork("ARBITRUM_RPC_URL")) return vm.skip(true);
        address pool = 0xbE3aD6a5669Dc0B8b12FeBC03608860C31E2eef6;
        DepositFactory f = deployReal();
        DepositAccount a = DepositAccount(f.deploy(ALICE, owners()));
        PoolUser user = new PoolUser();

        uint256 snap = vm.snapshotState();
        deal(ARB_USDT0, address(user), 1_000e6);
        uint256 market = user.swapIn(pool, ARB_USDT0, false, 1_000e6);
        vm.revertToState(snap);
        emit log_named_uint("the pool's USDC for 1,000 USDT0 at the fork block", market);

        assertGe(market, 998e6, "today's market is within the 0.2% bound");
        deal(ARB_USDT0, address(a), 2_000e6);
        uint256 before = IERC20(ARB_USDC).balanceOf(address(a));
        vm.prank(TRANSFER);
        uint256 out = a.convertSwap(1_000e6, 0);
        emit log_named_uint("USDC out for 1,000 USDT0 at the fork block's market", out);
        assertGe(out, 998e6, "at least 1 USD less the bound");
        assertEq(IERC20(ARB_USDT0).balanceOf(address(a)), 1_000e6);
        assertEq(IERC20(ARB_USDC).balanceOf(address(a)) - before, out);

        // move the market below the bound (USDT0 sold into the pool): refused, the USDT0 kept
        // (in 10,000 steps until a quote reads below 998: the pool's liquidity is thick at the peg)
        uint256 low = market;
        for (uint256 i; i < 100 && low >= 998e6; ++i) {
            deal(ARB_USDT0, address(user), 10_000e6);
            user.swapIn(pool, ARB_USDT0, false, 10_000e6);
            snap = vm.snapshotState();
            deal(ARB_USDT0, address(user), 1_000e6);
            low = user.swapIn(pool, ARB_USDT0, false, 1_000e6);
            vm.revertToState(snap);
        }
        emit log_named_uint("the pool's USDC for 1,000 USDT0, the market moved down", low);
        assertLt(low, 998e6);
        vm.prank(TRANSFER);
        vm.expectRevert(DepositAccount.BelowMinimum.selector);
        a.convertSwap(1_000e6, 0);
        assertEq(IERC20(ARB_USDT0).balanceOf(address(a)), 1_000e6);
        vm.prank(STRANGER);
        vm.expectRevert(DepositAccount.NotAllowed.selector);
        a.convertSwap(1, 0);
    }

    function test_arbitrum_burnByCctpToThisSameAddress() public {
        if (!fork("ARBITRUM_RPC_URL")) return vm.skip(true);
        DepositFactory f = deployReal();
        DepositAccount a = DepositAccount(f.deploy(ALICE, owners()));
        deal(ARB_USDC, address(a), 250e6);
        uint256 supply = IERC20(ARB_USDC).totalSupply();
        vm.prank(TRANSFER);
        a.convertBurn(250e6, 0);
        assertEq(supply - IERC20(ARB_USDC).totalSupply(), 250e6, "burned");
        assertEq(IERC20(ARB_USDC).balanceOf(address(a)), 0);
    }

    // ── HyperEVM alone ───────────────────────────────────────────────────────────────────────

    /// HyperEVM's TokenMessengerV2 has a minimum fee its controller may raise (0 today). Raised, a burn
    /// with `maxFee` 0 reverts; the account reads the minimum and pays it, up to its cap.
    function test_hyperevm_aBurnPaysTheMessengersRaisedMinimumFee() public {
        if (!fork("HYPEREVM_RPC_URL")) return vm.skip(true);
        address usdc = 0xb88339CB7199b77E23DB6E890353E22632Ba630f;
        IMinFeeMessenger tm = IMinFeeMessenger(0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d);
        DepositFactory f = deployReal();
        DepositAccount a = DepositAccount(f.deploy(ALICE, owners()));
        vm.prank(tm.minFeeController());
        tm.setMinFee(5_000); // per 1e7: 5 bp
        uint256 fee = tm.getMinFeeAmount(100e6);
        emit log_named_uint("HyperEVM's minimum fee for 100 USDC at minFee 5,000", fee);
        assertGt(fee, 0);
        assertEq(a.burnMinFee(100e6), fee);

        // what a zero max fee now meets
        deal(usdc, address(this), 100e6);
        IERC20(usdc).approve(address(tm), 100e6);
        vm.expectRevert(bytes("Insufficient max fee"));
        tm.depositForBurn(100e6, 3, bytes32(uint256(uint160(address(this)))), usdc, bytes32(0), 0, 2000);

        deal(usdc, address(a), 100e6);
        uint256 supply = IERC20(usdc).totalSupply();
        vm.prank(TRANSFER);
        a.convertBurn(100e6, 3);
        assertEq(supply - IERC20(usdc).totalSupply(), 100e6, "burned, the fee paid at the mint");
        assertEq(IERC20(usdc).balanceOf(address(a)), 0);

        vm.prank(tm.minFeeController());
        tm.setMinFee(20_000); // 20 bp: above the account's 10 bp cap
        deal(usdc, address(a), 100e6);
        vm.prank(TRANSFER);
        vm.expectRevert(DepositAccount.BurnFeeTooHigh.selector);
        a.convertBurn(100e6, 3);
        assertEq(IERC20(usdc).balanceOf(address(a)), 100e6, "kept, withdrawable");
    }

    function test_hyperevm_aCopyReceivesAndThePasskeyFallsBack() public {
        if (!fork("HYPEREVM_RPC_URL")) return vm.skip(true);
        assertFalse(precompilePresent());
        DepositFactory f = deployReal();
        DepositAccount a = DepositAccount(f.deploy(ALICE, owners()));
        bytes32 self = bytes32(uint256(uint160(address(a))));
        Credential[] memory next = two(passkey(PASSKEY_A), passkey(PASSKEY_B));
        bytes memory body = abi.encode(a.RECORD_TAG(), uint64(5), uint64(vm.getBlockTimestamp()), DEST, next);
        vm.prank(MT);
        assertTrue(a.handleReceiveFinalizedMessage(3, self, 2000, body));
        assertEq(a.version(), 5);
        assertEq(a.withdrawalAddress(), DEST);
        bytes32 d = keccak256("x");
        assertTrue(a.checkOwnerSignature(d, signPasskey(PASSKEY_B, d)));
        assertFalse(a.checkOwnerSignature(d, signWallet(WALLET_A, d)));
        // another sender, another domain, unfinalized: refused
        vm.prank(MT);
        vm.expectRevert(DepositAccount.NotHomeMessage.selector);
        a.handleReceiveFinalizedMessage(19, self, 2000, body);
        vm.prank(MT);
        vm.expectRevert(DepositAccount.NotFinalized.selector);
        a.handleReceiveUnfinalizedMessage(3, self, 1000, body);
    }
}
