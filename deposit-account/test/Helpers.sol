// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Credential, DepositAccount, StrategyGrant, Withdrawal} from "../src/DepositAccount.sol";
import {DepositFactory} from "../src/DepositFactory.sol";

/// A plain ERC-20; `quiet` makes `transfer` and `approve` return nothing, as Ethereum's USDT does.
contract MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;
    bool public quiet;

    function setQuiet(bool q) external {
        quiet = q;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return _answer();
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return _answer();
    }

    function _answer() internal view returns (bool) {
        if (quiet) {
            assembly {
                return(0, 0)
            }
        }
        return true;
    }
}

/// A vault for the fixture factory: code at an address, nothing else.
contract FixtureVault {
    bytes32 public immutable strategyId;

    constructor(bytes32 strategyId_) {
        strategyId = strategyId_;
    }
}

/// THE FIXTURE FACTORY (amendment 1, §5): a test-only vault factory with `create` and `authorisedFor`,
/// for chains slice 2's real factory refuses (`WrongChain`: it is pinned to Arbitrum and HyperEVM),
/// such as Ethereum's flow. It checks nothing an owner signs; the real factory's `create` validates the
/// whole configuration and the owner's `CreateVault` signature (the Arbitrum cross-slice fork test).
contract FixtureVaultFactory {
    struct Info {
        address owner;
        bytes32 strategyId;
        bytes32 configHash;
    }

    mapping(address => Info) public info;

    function create(bytes32 strategyId, address owner, bytes32 configHash) external returns (address vault) {
        vault = address(new FixtureVault(strategyId));
        info[vault] = Info(owner, strategyId, configHash);
    }

    /// Registers any address, with code or not (to test the account's own checks).
    function register(address vault, address owner, bytes32 strategyId, bytes32 configHash) external {
        info[vault] = Info(owner, strategyId, configHash);
    }

    function authorisedFor(address vault)
        external
        view
        returns (address owner, bytes32 strategyId, bytes32 configHash)
    {
        Info memory i = info[vault];
        return (i.owner, i.strategyId, i.configHash);
    }
}

/// Circle's MessageTransmitterV2, etched at its address: records `sendMessage` and delivers to a
/// handler as the transmitter would.
contract MockTransmitter {
    uint32 public lastDomain;
    bytes32 public lastRecipient;
    bytes32 public lastCaller;
    uint32 public lastThreshold;
    bytes public lastBody;
    address public lastSender;
    uint256 public sent;

    function sendMessage(uint32 d, bytes32 recipient, bytes32 caller, uint32 threshold, bytes calldata body) external {
        (lastDomain, lastRecipient, lastCaller, lastThreshold, lastBody, lastSender) =
            (d, recipient, caller, threshold, body, msg.sender);
        ++sent;
    }

    function body() external view returns (bytes memory) {
        return lastBody;
    }
}

/// Circle's TokenMessengerV2, etched at its address: pulls and burns what `depositForBurn` names.
contract MockTokenMessenger {
    uint256 public amount;
    uint32 public domain;
    bytes32 public mintRecipient;
    address public burnToken;
    bytes32 public destinationCaller;
    uint256 public maxFee;
    uint32 public threshold;
    /// HyperEVM's messenger has a minimum fee, per 1e7 of the amount; Arbitrum's has no such function.
    bool public hasMinFee;
    uint256 public minFee;

    function setMinFee(bool has, uint256 perE7) external {
        (hasMinFee, minFee) = (has, perE7);
    }

    function getMinFeeAmount(uint256 a) public view returns (uint256) {
        require(hasMinFee, "no such function");
        return a * minFee / 1e7;
    }

    function depositForBurn(uint256 a, uint32 d, bytes32 r, address t, bytes32 c, uint256 f, uint32 th) external {
        if (hasMinFee) require(f >= getMinFeeAmount(a), "Insufficient max fee");
        MockToken(t).transferFrom(msg.sender, address(this), a);
        MockToken(t).burn(address(this), a);
        (amount, domain, mintRecipient, burnToken, destinationCaller, maxFee, threshold) = (a, d, r, t, c, f, th);
    }
}

interface ISwapCallback {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

/// A Uniswap V3 pool, etched at the pinned pool's address: pays `rateBp` of the amount in, then asks
/// for the input in its callback (or `overcharge` more).
contract MockPool {
    address public token0;
    address public token1;
    uint256 public rateBp;
    uint256 public overcharge;

    function init(address t0, address t1) external {
        (token0, token1) = (t0, t1);
    }

    function setRate(uint256 bp) external {
        rateBp = bp;
    }

    function setOvercharge(uint256 extra) external {
        overcharge = extra;
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1)
    {
        uint256 inAmt = uint256(amountSpecified);
        uint256 out = inAmt * rateBp / 10_000;
        (address tin, address tout) = zeroForOne ? (token0, token1) : (token1, token0);
        MockToken(tout).transfer(recipient, out);
        int256 owed = int256(inAmt + overcharge);
        (amount0, amount1) = zeroForOne ? (owed, -int256(out)) : (-int256(out), owed);
        uint256 before = MockToken(tin).balanceOf(address(this));
        ISwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
        require(MockToken(tin).balanceOf(address(this)) >= before + inAmt + overcharge, "not paid");
    }
}

/// A contract wallet that answers EIP-1271 for anything: an account must never accept it.
contract ContractWallet {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0x1626ba7e;
    }
}

abstract contract Helpers is Test {
    address constant DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes constant DEPLOYER_RUNTIME =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";
    bytes32 constant FACTORY_SALT = keccak256("dltx.deposit-factory");

    /// P-256's order, for low-s signatures.
    uint256 constant P256_N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551;

    address constant RECOVERY = address(0xBEEF02);
    address constant TRANSFER = address(0xBEEF01);
    address constant STRANGER = address(0xBEEF03);
    address constant FEES = address(0xFEE5);
    address constant DEST = address(0xD357);
    address constant DEST2 = address(0xD358);

    bytes32 constant ALICE = bytes32(uint256(uint128(bytes16(0x0192f1a2b3c47d8e9f00112233445566))));

    // the owner's keys: two wallets and two passkeys
    uint256 constant WALLET_A = 0xA11CE;
    uint256 constant WALLET_B = 0xB0B;
    uint256 constant PASSKEY_A = 0x5EC0DE;
    uint256 constant PASSKEY_B = 0x5EC0DF;

    function deployFactory() internal returns (DepositFactory) {
        if (DEPLOYER.code.length == 0) vm.etch(DEPLOYER, DEPLOYER_RUNTIME);
        (bool ok, bytes memory ret) =
            DEPLOYER.call(abi.encodePacked(FACTORY_SALT, type(DepositFactory).creationCode, abi.encode(RECOVERY)));
        require(ok && ret.length == 20, "deterministic deployment failed");
        return DepositFactory(address(bytes20(ret)));
    }

    function wallet(uint256 pk) internal pure returns (Credential memory) {
        return Credential(1, bytes32(uint256(uint160(vm.addr(pk)))), bytes32(0));
    }

    function walletOf(address a) internal pure returns (Credential memory) {
        return Credential(1, bytes32(uint256(uint160(a))), bytes32(0));
    }

    function passkey(uint256 pk) internal pure returns (Credential memory) {
        (uint256 x, uint256 y) = vm.publicKeyP256(pk);
        return Credential(2, bytes32(x), bytes32(y));
    }

    function one(Credential memory a) internal pure returns (Credential[] memory s) {
        s = new Credential[](1);
        s[0] = a;
    }

    function two(Credential memory a, Credential memory b) internal pure returns (Credential[] memory s) {
        s = new Credential[](2);
        (s[0], s[1]) = (a, b);
    }

    /// An account owned by two credentials (decision 76: a genesis holds exactly one): deployed with
    /// `firstPk`'s credential alone, then, at the home, `second` added by it and its 24 hours passed. On a
    /// copy, the second credential arrives with the home's record (`deliverRecord`).
    function deployTwo(DepositFactory f, bytes32 user, uint256 firstPk, Credential memory second)
        internal
        returns (DepositAccount a)
    {
        a = DepositAccount(f.deploy(user, one(credOf(firstPk))));
        if (a.isHome()) addNow(a, firstPk, second);
    }

    /// 0x01 ‖ r ‖ s ‖ v
    function signWallet(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(uint8(1), r, s, v);
    }

    /// A WebAuthn assertion as a browser's `navigator.credentials.get` returns it, the challenge being
    /// `digest`, signed by the P-256 key `pk`: authenticatorData with user presence and verification,
    /// clientDataJSON with its type first, then 0x02 ‖ x ‖ y ‖ (r, s, challengeIndex, typeIndex,
    /// authenticatorData, clientDataJSON).
    function signPasskey(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        return signPasskeyFlags(pk, digest, 0x05);
    }

    function signPasskeyFlags(uint256 pk, bytes32 digest, bytes1 flags) internal pure returns (bytes memory) {
        (uint256 x, uint256 y) = vm.publicKeyP256(pk);
        bytes memory authData = abi.encodePacked(sha256("app.dltx.org"), flags, uint32(7));
        string memory clientData = string.concat(
            '{"type":"webauthn.get","challenge":"',
            Base64.encodeURL(abi.encodePacked(digest)),
            '","origin":"https://app.dltx.org","crossOrigin":false}'
        );
        bytes32 h = sha256(abi.encodePacked(authData, sha256(bytes(clientData))));
        (bytes32 r, bytes32 s) = vm.signP256(pk, h);
        if (uint256(s) > P256_N / 2) s = bytes32(P256_N - uint256(s));
        return abi.encodePacked(
            uint8(2), bytes32(x), bytes32(y), abi.encode(r, s, uint256(23), uint256(1), authData, clientData)
        );
    }

    /// The credential a test key signs as.
    function credOf(uint256 pk) internal pure returns (Credential memory) {
        if (pk == PASSKEY_A || pk == PASSKEY_B) return passkey(pk);
        return wallet(pk);
    }

    /// Signs with whichever kind the key is: the passkeys are PASSKEY_A and PASSKEY_B.
    function sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        if (pk == PASSKEY_A || pk == PASSKEY_B) return signPasskey(pk, digest);
        return signWallet(pk, digest);
    }

    // ── owner messages ───────────────────────────────────────────────────────────────────────

    function typed(DepositAccount a, bytes memory encodedStruct) internal view returns (bytes32) {
        return a.hashTypedData(keccak256(encodedStruct));
    }

    function addCredential(DepositAccount a, uint256 signer, Credential memory c) internal {
        uint256 nonce = a.recordNonceOf(credOf(signer));
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 d = typed(a, abi.encode(a.ADD_CREDENTIAL_TYPEHASH(), c.kind, c.x, c.y, nonce, deadline));
        a.addCredential(c, nonce, deadline, sign(signer, d));
    }

    /// Proposes the addition and lets its 24 hours pass (decision 31).
    function addNow(DepositAccount a, uint256 signer, Credential memory c) internal {
        addCredential(a, signer, c);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
    }

    function cancelAddition(DepositAccount a, uint256 signer, Credential memory c, uint256 due) internal {
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 d = typed(a, abi.encode(a.CANCEL_ADDITION_TYPEHASH(), c.kind, c.x, c.y, due, deadline));
        a.cancelAddition(c, due, deadline, sign(signer, d));
    }

    /// Proposes the withdrawal address and lets its 24 hours pass (decision 32).
    function setWithdrawalNow(DepositAccount a, uint256 signer, address next) internal {
        setWithdrawal(a, signer, next);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
    }

    function proposeRemoval(DepositAccount a, uint256 signer, Credential memory c) internal {
        uint256 nonce = a.recordNonceOf(credOf(signer));
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 d = typed(a, abi.encode(a.REMOVE_CREDENTIAL_TYPEHASH(), c.kind, c.x, c.y, nonce, deadline));
        a.proposeRemoval(c, nonce, deadline, sign(signer, d));
    }

    function cancelRemoval(DepositAccount a, uint256 signer, Credential memory c, uint256 due) internal {
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 d = typed(a, abi.encode(a.CANCEL_REMOVAL_TYPEHASH(), c.kind, c.x, c.y, due, deadline));
        a.cancelRemoval(c, due, deadline, sign(signer, d));
    }

    function setWithdrawal(DepositAccount a, uint256 signer, address next) internal {
        uint256 nonce = a.recordNonceOf(credOf(signer));
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 d = typed(a, abi.encode(a.SET_WITHDRAWAL_ADDRESS_TYPEHASH(), next, nonce, deadline));
        a.setWithdrawalAddress(next, nonce, deadline, sign(signer, d));
    }

    function cancelWithdrawal(DepositAccount a, uint256 signer, address next, uint256 due) internal {
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 d = typed(a, abi.encode(a.CANCEL_WITHDRAWAL_ADDRESS_TYPEHASH(), next, due, deadline));
        a.cancelWithdrawalAddress(next, due, deadline, sign(signer, d));
    }

    function revokeSig(DepositAccount a, uint256 signer, bool revoke)
        internal
        view
        returns (uint256 nonce, uint256 deadline, bytes memory sig)
    {
        nonce = a.localNonceOf(credOf(signer));
        deadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 th = revoke ? a.REVOKE_TRANSFER_TYPEHASH() : a.ALLOW_TRANSFER_TYPEHASH();
        sig = sign(signer, typed(a, abi.encode(th, block.chainid, nonce, deadline)));
    }

    /// The owner's `AuthoriseStrategy` (amendment 1), signed with the signer's next local nonce.
    function grantSig(
        DepositAccount a,
        uint256 signer,
        address vaultFactory,
        uint32 domain,
        bytes32 strategyId,
        bytes32 configHash,
        uint256 amount
    ) internal view returns (StrategyGrant memory g, bytes memory sig) {
        g = StrategyGrant(
            vaultFactory, domain, strategyId, configHash, amount, a.localNonceOf(credOf(signer)), vm.getBlockTimestamp() + 1 hours
        );
        sig = sign(
            signer,
            typed(
                a,
                abi.encode(
                    a.AUTHORISE_STRATEGY_TYPEHASH(),
                    block.chainid,
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

    function authorise(
        DepositAccount a,
        uint256 signer,
        address vaultFactory,
        uint32 domain,
        bytes32 strategyId,
        bytes32 configHash,
        uint256 amount
    ) internal returns (uint256 id) {
        (StrategyGrant memory g, bytes memory sig) = grantSig(a, signer, vaultFactory, domain, strategyId, configHash, amount);
        id = a.authoriseStrategy(g, sig);
    }

    function cancelTrust(DepositAccount a, uint256 signer, address vaultFactory, uint32 domain, uint256 due) internal {
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 d = typed(a, abi.encode(a.CANCEL_TRUST_TYPEHASH(), vaultFactory, domain, due, deadline));
        a.cancelTrust(vaultFactory, domain, due, deadline, sign(signer, d));
    }

    /// When the (factory, domain) trust takes or took effect (0: none).
    function dueOf(DepositAccount a, address vaultFactory, uint32 domain) internal view returns (uint256 due) {
        (due,) = a.trustOf(vaultFactory, domain);
    }

    /// A withdrawal to the account's withdrawal address and the factory's fee recipient in effect now.
    function withdrawal(DepositAccount a, address token, uint256 amount, uint256 maxFee)
        internal
        view
        returns (Withdrawal memory w)
    {
        address recipient = DepositFactory(a.factory()).feeRecipient();
        w = Withdrawal(token, amount, a.withdrawalAddress(), maxFee, recipient, 0, vm.getBlockTimestamp() + 1 hours);
    }

    /// Signs `w` with the signer's next local nonce, written into `w` (a memory reference).
    function signWithdrawal(DepositAccount a, uint256 signer, Withdrawal memory w) internal view returns (bytes memory) {
        w.nonce = a.localNonceOf(credOf(signer));
        return sign(
            signer,
            typed(
                a,
                abi.encode(
                    a.WITHDRAW_TYPEHASH(),
                    block.chainid,
                    w.token,
                    w.amount,
                    w.to,
                    w.maxFee,
                    w.feeRecipient,
                    w.nonce,
                    w.deadline
                )
            )
        );
    }

    /// Brings a copy in sync with the home's record of `version`, as Circle's transmitter delivers it.
    function deliverRecord(DepositAccount a, uint64 version, address withdrawalAddress, Credential[] memory creds)
        internal
    {
        bytes memory body = abi.encode(a.RECORD_TAG(), version, uint64(vm.getBlockTimestamp()), withdrawalAddress, creds);
        vm.prank(0x81D40F21F12A8F0E3252Bccb954D722d4c464B64);
        a.handleReceiveFinalizedMessage(3, bytes32(uint256(uint160(address(a)))), 2000, body);
    }
}
