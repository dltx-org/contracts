// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

/*
 * THE INTERFACE WITH SLICE 1a (`contracts/deposit-account`, `DepositAccount.sol` on feat/deposit-account
 * 2252c6cc9): what a vault and the vault factory ask of the user's deposit account, the vault's `owner`
 * (spec §7, §8.2, §8.3), and what the deposit account asks the vault factory. The one file where the
 * two projects meet.
 *
 * The owner is the user's deposit account on the SAME chain: the home on Arbitrum, the registry-only
 * copy on HyperEVM (§7.3), both at the same address (one deposit factory, one salt per user). That is
 * what lets one `BeginExit` signature work on both halves: the EIP-712 domain names the account and no
 * chain id (§7.2).
 */

/// One owner credential, as the deposit account stores it. A wallet: kind 1, `x` the address
/// left-padded, `y` zero. A passkey: kind 2, `x` and `y` the P-256 public key.
struct Credential {
    uint8 kind;
    bytes32 x;
    bytes32 y;
}

interface IDepositOwner {
    /// Whether a credential in effect on this chain signed `digest`, a full EIP-712 digest in the
    /// account's "DLTX Owner" domain. `signature` is 0x01 ‖ r ‖ s ‖ v for a wallet, or 0x02 ‖ x ‖ y ‖
    /// the ABI-encoded WebAuthn assertion for a passkey. Never reverts on a bad signature.
    function checkOwnerSignature(bytes32 digest, bytes calldata signature) external view returns (bool);

    /// The withdrawal address in effect now (zero until the owner sets one). Only the hub reads it: its
    /// exit pays it on the hub's chain (§8.4); a leg's exit sends to the hub (amendment 2a, decision 46).
    function withdrawalAddress() external view returns (address);

    /// Whether `c` is a credential in effect in this chain's record (the copy's, on HyperEVM): an
    /// addition still within its 24 hours (decision 31) is not, and can't sign either.
    function isCredential(Credential calldata c) external view returns (bool);

    /// `isCredential` by the credential's id, keccak256(abi.encode(kind, x, y)): what a vault keeps of
    /// the credential that signed an action it applies later (the Hyperliquid leg's agent choice).
    function isCredentialId(bytes32 id) external view returns (bool);

    /// The home always; a copy while the home's record it received was published within 30 days
    /// (`RECORD_TTL`, the partner's audit M1). An unsynced copy (never reached, or expired) accepts no owner
    /// signature (`checkOwnerSignature`, `isCredential`, `isCredentialId` false) and names no withdrawal
    /// address: on HyperEVM, no owner action, no `BeginExit` by signature and no vault creation until a
    /// fresh `publish` arrives.
    function synced() external view returns (bool);
}

/// What the deposit account's `fund(vaultFactory, vault, amount)` asks a vault factory (§8.2, decision
/// 16; amendment 1 §2.3), now a combination factory (amendment 2a): the account that owns `vault`, the
/// strategy id and the configuration hash its owner signed — for a strategy's HUB only; zeros for any
/// other address (a leg, or one the factory never created). Not to be confused with `VaultRegistry`,
/// the execution keys' registry. The account funds the vault only when
/// `owner == address(this)`, within the allowance its owner authorised for exactly that strategy and
/// configuration (`authoriseStrategy`, keyed by keccak256(strategyId, configHash), per token, additive),
/// so one authorisation funds exactly one vault.
interface IVaultFunding {
    function authorisedFor(address vault) external view returns (address owner, bytes32 strategyId, bytes32 configHash);
}

/// The owner's EIP-712 domain (§7.2): name "DLTX Owner", version "1", the deposit account's address,
/// and NO chain id — `DepositAccount.domainSeparator()` exactly. The vault builds the digest itself.
library OwnerDomain {
    bytes32 internal constant DOMAIN_TYPEHASH = keccak256("EIP712Domain(string name,string version,address verifyingContract)");
    bytes32 internal constant NAME_HASH = keccak256("DLTX Owner");
    bytes32 internal constant VERSION_HASH = keccak256("1");
    uint8 internal constant WALLET = 1;

    function separator(address owner) internal pure returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, owner));
    }

    function digest(address owner, bytes32 structHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(hex"1901", separator(owner), structHash));
    }

    function wallet(address a) internal pure returns (Credential memory) {
        return Credential(WALLET, bytes32(uint256(uint160(a))), bytes32(0));
    }
}
