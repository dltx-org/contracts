// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {
    Credential,
    DepositAccountState,
    IDepositFactory,
    IMessageTransmitterV2,
    ITokenMessengerV2,
    IUniswapV3Pool,
    IVaultFactory,
    StrategyGrant,
    Withdrawal
} from "./DepositAccountState.sol";

/*
 * The user's deposit contract — docs/architecture/rework/specs/step-11e2-strategy-vault-design.md
 * §7 (the owner) and §8.2 (the deposit contract); owner-upgrades-design.md Part B (the upgrade).
 *
 * One per user: a fixed ERC-1967 proxy (`DepositProxy`) made by `DepositFactory` at the same address
 * on every chain, its salt hashing the user's id and their FIRST OWNER SET (decision 22): whoever
 * deploys it, it starts with the user's own credentials, on the factory's genesis version (Q0). This is
 * the code it runs (version 1); the owner record (its changes, the copies, the upgrade) is in its
 * record module, `DepositAccountRecord`, reached through `fallback` for every selector not here, in
 * this account's storage (`DepositAccountState`).
 *
 * THE OWNER is a set of at most four credentials, each a plain address (an EOA, verified by ECDSA
 * recovery only: no EIP-1271, decision 29) or a passkey's P-256 public key (verified as a WebAuthn
 * assertion by OpenZeppelin's WebAuthn, the challenge being the EIP-712 digest). Owner messages are
 * EIP-712 in the domain "DLTX Owner", version "1", this contract's address and NO chain id (§7.2):
 *   - record changes (credentials, the withdrawal address, an upgrade) are accepted at the HOME only,
 *     the copy on Arbitrum (chain 42161), with the signing credential's own record nonce and an expiry;
 *     every other chain's copy learns the record, and the code the home moved to, by the home's own
 *     Circle message (`publish`, `publishUpgrade`, §7.3);
 *   - local actions (a signed withdrawal, revoking or allowing the transfer key, authorising a
 *     strategy) name the chain id and carry the signing credential's own local nonce on this chain
 *     and an expiry;
 *   - cancelling a pending change carries no nonce: it names the change and its due time, so a
 *     replay can only cancel again, and nobody can starve it by consuming nonces (README, Decisions).
 *
 * MONEY leaves only to the owner's withdrawal address, to a DEPLOYED vault of THIS owner registered by a
 * vault factory the owner trusts on this chain (within the USDC allowance the owner signed for that
 * factory, strategy and configuration), to the platform's fee address for a fee the owner signed, into
 * the pinned USDT→USDC pool, or by a CCTP burn to this same address on another deposit chain.
 * A vault factory becomes trusted by the owner's signature alone, 24 hours after the first
 * authorisation naming it (amendment 1, decision 35), at once for DLTX's pinned combination factory on
 * Arbitrum and HyperEVM (deposit-first-deposit-design.md, D2); a copy learns the trust and the allowance from
 * the home's own message. No open-ended call, no selfdestruct; the one delegatecall is to the record
 * module, an immutable whose code hash the constructor checks (owner-upgrades-design.md §4.6).
 *
 * Compiled for `cancun`: OpenZeppelin 5.6.1's WebAuthn slices bytes with MCOPY (README, Decisions).
 */
contract DepositAccount is DepositAccountState {
    /// DLTX's combination factory, deployed by DLTX at this address on Arbitrum (domain 3) and HyperEVM
    /// (domain 19) only: an authorisation naming it for one of those two domains trusts it at once (D2).
    /// Anyone may deploy its code at this address elsewhere, where its pins name nothing: there it waits.
    /// The vault build's version-1 combination factory (owner-upgrades-design.md §8): the deterministic
    /// deployer, salt keccak256("dltx.vault.v1.factory"), for that build's RECOVERY (contracts/strategy-vault-v1
    /// script/DeployV1.s.sol `factoryOf`); it moves with that build and that key (scripts/repin-v1.mjs).
    address internal constant PINNED_VAULT_FACTORY = 0xF6989dDcf67CcbC1077C9054D62F8A1363623d1d;

    /// This version's record module (owner-upgrades-design.md §3.3): created before this code, its code
    /// hash checked here, never changeable.
    address public immutable module;

    constructor(address factory_, address module_, bytes32 moduleCodeHash) DepositAccountState(factory_) {
        if (moduleCodeHash == bytes32(0) || moduleCodeHash == keccak256("") || module_.codehash != moduleCodeHash) {
            revert BadModule();
        }
        module = module_;
    }

    modifier nonReentrant() {
        if (_entered) revert Reentered();
        _entered = true;
        _;
        _entered = false;
    }

    /// The record module's functions run here, in this account's storage. Its own dispatcher refuses a
    /// selector it does not have (owner-upgrades-design.md §3.3). Not payable: version 1 takes no coin.
    fallback() external {
        address m = module;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), m, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }

    /// Factory only, once, in the transaction that deploys the proxy: the genesis owner set, exactly
    /// one credential (amendment 2d, decision 76): a co-owner can't hide in the address, and any
    /// further credential is an addition with its 24 hours.
    function initialize(Credential[] calldata owners) external {
        if (msg.sender != factory) revert NotFactory();
        if (_initialised) revert AlreadyInitialised();
        if (owners.length != 1) revert BadOwnerSet();
        // the shape only: an account must be deployable wherever money already waits at its
        // address, whatever code a wallet has on that chain; EOA-only is enforced before an
        // address is ever shown (README, Decisions)
        if (!_validCredential(owners[0], false)) revert BadCredential();
        _creds.push(owners[0]);
        _initialised = true;
        _deployedAt = uint64(block.timestamp);
        emit Initialised(owners);
    }

    // ── views ────────────────────────────────────────────────────────────────────────────────

    /// The implementation this account runs (the ERC-1967 slot; zero when called on code directly).
    function implementation() external view returns (address) {
        return _implementation();
    }

    /// The pending upgrade (zeros if none): its target, the target's listed version and when anyone may
    /// apply it. Still cancellable after its due time, until applied (owner-upgrades-design.md Q9).
    function pendingUpgrade() external view returns (address impl, uint256 codeVersion, uint256 due) {
        impl = _upgradeTo;
        if (impl != address(0)) return (impl, IDepositFactory(factory).versionOf(impl), _upgradeDue);
    }

    /// Whether credential `id` has a removal proposed and not yet settled (always false on a copy:
    /// removals are the home's). A vault's upgrade path refuses such a scheduler (§3.4, I10).
    function removalPendingOf(bytes32 id) external view returns (bool) {
        return _removalDue[id] != 0;
    }

    /// The next record-change nonce of credential `c` (home only).
    function recordNonceOf(Credential calldata c) external view returns (uint256) {
        return _recordNonce[credentialId(c)];
    }

    /// The next local-action nonce of credential `c` on this chain.
    function localNonceOf(Credential calldata c) external view returns (uint256) {
        return _localNonce[credentialId(c)];
    }

    /// What the transfer key may still pay the vault of `vaultFactory` with `strategyId` and
    /// `configHash`, in this chain's USDC.
    function allowanceOf(address vaultFactory, bytes32 strategyId, bytes32 configHash) external view returns (uint256) {
        return allowance[vaultKey(vaultFactory, strategyId, configHash)];
    }

    /// When `vaultFactory`'s trust for `domain` took or takes effect here (0: untrusted, or cancelled),
    /// and how many times that pair's trust was proposed.
    function trustOf(address vaultFactory, uint32 domain) external view returns (uint256 due, uint256 epoch) {
        Trust storage t = _trust[trustKey(vaultFactory, domain)];
        return (t.due, t.epoch);
    }

    /// The home's authorisation `id` (zeros if none).
    function grant(uint256 id) external view returns (Grant memory) {
        return _grants[id];
    }

    /// The withdrawal address in effect now (zero until the owner sets one, and on an unsynced copy).
    function withdrawalAddress() public view returns (address) {
        if (!synced()) return address(0);
        return _due(_pendingWithdrawalDue) ? _pendingWithdrawal : _withdrawal;
    }

    /// A withdrawal-address change still waiting for its 24 hours (zeros if none).
    function pendingWithdrawalAddress() external view returns (address next, uint256 due) {
        if (_pendingWithdrawalDue != 0 && !_due(_pendingWithdrawalDue)) return (_pendingWithdrawal, _pendingWithdrawalDue);
    }

    /// When a credential's pending removal takes effect (0: none, or already in effect).
    function removalDue(Credential calldata c) external view returns (uint256 due) {
        due = _removalDue[credentialId(c)];
        if (_due(due)) due = 0;
    }

    /// When a credential's pending addition takes effect (0: none, or already in effect).
    function additionDue(Credential calldata c) external view returns (uint256 due) {
        bytes32 id = credentialId(c);
        if (_indexOf(id) == type(uint256).max) return 0;
        due = _addDue[id];
        if (_due(due)) due = 0;
    }

    /// The record's version in effect now; a copy is complete when it equals the home's.
    function version() external view returns (uint64 v) {
        v = _version;
        if (_due(_pendingWithdrawalDue)) ++v;
        for (uint256 i; i < _creds.length; ++i) {
            bytes32 id = credentialId(_creds[i]);
            if (_due(_removalDue[id])) ++v;
            if (_due(_addDue[id])) ++v;
        }
    }

    function isCredential(Credential calldata c) external view returns (bool) {
        return _isCredential(credentialId(c));
    }

    /// `isCredential` by the credential's id (`credentialId`): what a vault keeps of the credential that
    /// signed an action it applies later (the Hyperliquid leg's agent choice, the partner's audit M2).
    function isCredentialId(bytes32 id) external view returns (bool) {
        return _isCredential(id);
    }

    /// Whether a credential in effect on this chain signed `digest` (for the vaults and the vault
    /// factory, which verify the owner's other messages, `BeginExit` among them, through here).
    /// `signature` is 0x01 ‖ r ‖ s ‖ v for a wallet, or 0x02 ‖ x ‖ y ‖ the ABI-encoded WebAuthn
    /// assertion (r, s, challengeIndex, typeIndex, authenticatorData, clientDataJSON) for a passkey.
    function checkOwnerSignature(bytes32 digest, bytes calldata signature) external view returns (bool) {
        return _signer(digest, signature) != bytes32(0);
    }

    // ── local owner actions (§7.2: the chain named, the signer's nonce here) ──────────────────

    function revokeTransfer(uint256 nonce, uint256 deadline, bytes calldata signature) external {
        _localAction(keccak256(abi.encode(REVOKE_TRANSFER_TYPEHASH, block.chainid, nonce, deadline)), nonce, deadline, signature);
        transferRevoked = true;
        emit TransferRevoked(true);
    }

    function allowTransfer(uint256 nonce, uint256 deadline, bytes calldata signature) external {
        _localAction(keccak256(abi.encode(ALLOW_TRANSFER_TYPEHASH, block.chainid, nonce, deadline)), nonce, deadline, signature);
        transferRevoked = false;
        emit TransferRevoked(false);
    }

    /// At the home only (amendment 1, §2.1): the owner's authorisation of `g.allowance` USDC, on the
    /// deposit chain of `g.domain`, for the one vault of `g.vaultFactory` with `g.strategyId` and
    /// `g.configHash`. It gets an id (a counter per account), the same in every dispatch. A factory not
    /// yet trusted FOR THAT DOMAIN becomes trusted for it 24 hours after the first authorisation naming
    /// the pair, cancellable until then (`cancelTrust`), or at once for PINNED_VAULT_FACTORY on domain 3
    /// or 19 (never pending, so never cancellable); later ones wait for that same trust. One grant
    /// is at most MAX_GRANT. For domain 3 the allowance is added
    /// here once the trust is in effect (at once, or by `applyAuthorisation`); for another domain it is
    /// only recorded, for `dispatchAuthorisation`.
    function authoriseStrategy(StrategyGrant calldata g, bytes calldata signature) external returns (uint256 id) {
        if (!isHome()) revert NotHome();
        _localAction(
            keccak256(
                abi.encode(
                    AUTHORISE_STRATEGY_TYPEHASH,
                    block.chainid,
                    g.vaultFactory,
                    g.domain,
                    g.strategyId,
                    g.configHash,
                    g.allowance,
                    g.nonce,
                    g.deadline
                )
            ),
            g.nonce,
            g.deadline,
            signature
        );
        if (g.vaultFactory == address(0) || g.configHash == bytes32(0) || g.allowance == 0 || g.allowance > MAX_GRANT) {
            revert BadAmount();
        }
        if (!_depositDomain(g.domain)) revert BadDomain();
        Trust storage t = _trust[trustKey(g.vaultFactory, g.domain)];
        if (t.due == 0) {
            bool pinned = g.vaultFactory == PINNED_VAULT_FACTORY && (g.domain == HOME_DOMAIN || g.domain == 19);
            t.due = uint64(pinned ? block.timestamp : block.timestamp + DELAY);
            t.epoch += 1;
            emit TrustProposed(g.vaultFactory, g.domain, t.due, t.epoch);
        }
        id = ++authorisationCount;
        _grants[id] = Grant(g.vaultFactory, g.domain, false, g.strategyId, g.configHash, g.allowance, t.epoch);
        emit StrategyAuthorised(id, g.vaultFactory, g.domain, g.strategyId, g.configHash, g.allowance, t.due, t.epoch);
        if (g.domain == HOME_DOMAIN && _due(t.due)) _apply(id);
    }

    /// Anyone, at the home: adds a domain-3 authorisation made while its factory's trust was pending,
    /// once that same trust is in effect.
    function applyAuthorisation(uint256 id) external {
        if (!isHome()) revert NotHome();
        Grant storage g = _grants[id];
        if (g.vaultFactory == address(0)) revert NoGrant();
        if (g.domain != HOME_DOMAIN) revert BadDomain();
        if (g.applied) revert AlreadyApplied();
        if (!_trustedUnder(g)) revert NotTrusted();
        _apply(id);
    }

    /// Anyone, at the home, as often as needed (a message lost or expired): sends authorisation `id`
    /// for another deposit chain to this same address there, once its factory's trust is in effect.
    /// The copy applies each id once.
    function dispatchAuthorisation(uint256 id) external {
        if (!isHome()) revert NotHome();
        Grant storage g = _grants[id];
        if (g.vaultFactory == address(0)) revert NoGrant();
        if (g.domain == HOME_DOMAIN) revert BadDomain();
        if (!_trustedUnder(g)) revert NotTrusted();
        IMessageTransmitterV2(MESSAGE_TRANSMITTER).sendMessage(
            g.domain,
            bytes32(uint256(uint160(address(this)))),
            bytes32(0),
            FINALIZED,
            abi.encode(AUTH_TAG, id, g.vaultFactory, g.strategyId, g.configHash, g.allowance)
        );
        emit AuthorisationDispatched(id, g.domain);
    }

    /// Any credential in effect, before a (factory, domain) pending trust takes effect: it voids every
    /// authorisation granted under it, for good (their epoch never comes back). No nonce: it names the
    /// trust and its due time.
    function cancelTrust(address vaultFactory, uint32 domain, uint256 due, uint256 deadline, bytes calldata signature)
        external
    {
        _cancel(keccak256(abi.encode(CANCEL_TRUST_TYPEHASH, vaultFactory, domain, due, deadline)), deadline, signature);
        Trust storage t = _trust[trustKey(vaultFactory, domain)];
        if (due == 0 || t.due != due || block.timestamp >= due) revert NothingPending();
        t.due = 0;
        emit TrustCancelled(vaultFactory, domain, due);
    }

    // ── money (§8.2) ─────────────────────────────────────────────────────────────────────────

    /// Pays `amount` of `token` (zero: the native coin) to the withdrawal address. By a wallet
    /// credential itself (less the flat `EXIT_FEE`, which it chose to pay), by the transfer key unless
    /// revoked, and by ANYONE once the transfer key has not checked this version in for 7 days (the
    /// escape hatch, decision 17, owner-upgrades-design.md §A8): neither of the last two takes a fee, so
    /// no caller but the owner can turn the owner's money into fees a dollar at a time (amendment E).
    function withdraw(address token, uint256 amount) external nonReentrant {
        if (!synced()) revert NotSynced(); // never to a replaced address (M1)
        _settle();
        IDepositFactory f = IDepositFactory(factory);
        bool owner = _isCredential(_walletId(msg.sender));
        if (!owner && !(msg.sender == f.transferKey() && !transferRevoked) && !f.stopped(CODE_VERSION())) {
            revert NotAllowed();
        }
        address to = _withdrawal;
        if (to == address(0)) revert NoWithdrawalAddress();
        uint256 fee = owner ? _takeFee(token, amount) : 0;
        _send(token, to, amount - fee);
        emit Withdrawn(token, to, amount - fee, fee, msg.sender);
    }

    /// The owner's signed withdrawal, submitted by anyone: `w.amount` leaves (above the fee, when one is
    /// due), the flat `EXIT_FEE` of it to the factory's fee recipient when that transfer succeeds, the
    /// rest to the withdrawal address (decision 19, amendment E). The owner signs at least that fee as
    /// `w.maxFee` for USDC and USDT, always (whether a fee turns out due or not: one rule for every
    /// signature); the second argument is kept for the ABI and ignored. Both destinations are signed
    /// and must still be the ones in effect: a signature played after the withdrawal address or the
    /// fee recipient changed reverts. Consumed once.
    function withdrawSigned(Withdrawal calldata w, uint256, bytes calldata signature) external nonReentrant {
        _localAction(
            keccak256(
                abi.encode(
                    WITHDRAW_TYPEHASH,
                    block.chainid,
                    w.token,
                    w.amount,
                    w.to,
                    w.maxFee,
                    w.feeRecipient,
                    w.nonce,
                    w.deadline
                )
            ),
            w.nonce,
            w.deadline,
            signature
        );
        address to = _withdrawal;
        if (to == address(0)) revert NoWithdrawalAddress();
        if (w.to != to) revert NotWithdrawalAddress();
        if (w.feeRecipient != IDepositFactory(factory).feeRecipient()) revert NotFeeRecipient();
        if (_exitFee(w.token) > w.maxFee) revert FeeAboveMax();
        uint256 fee = _takeFee(w.token, w.amount);
        _send(w.token, to, w.amount - fee);
        emit Withdrawn(w.token, to, w.amount - fee, fee, msg.sender);
    }

    /// Transfer key only (amendment 1, §2.3): pays `amount` of this chain's USDC to `vault`, a deployed
    /// vault that `vaultFactory` (trusted by this account on this chain) registered to THIS account,
    /// within the allowance the owner authorised for that factory, strategy and configuration, and
    /// only once a withdrawal address is in effect (§8.2).
    function fund(address vaultFactory, address vault, uint256 amount) external nonReentrant {
        _settle();
        _transferKeyOnly();
        if (_withdrawal == address(0)) revert NoWithdrawalAddress();
        (address usdc, uint32 local) = cctpUsdc();
        if (usdc == address(0)) revert ConversionUnavailable();
        if (!isTrusted(vaultFactory, local)) revert NotTrusted();
        if (vault.code.length == 0) revert NotOwnVault();
        (address owner, bytes32 strategyId, bytes32 configHash) = IVaultFactory(vaultFactory).authorisedFor(vault);
        if (owner != address(this) || configHash == bytes32(0)) revert NotOwnVault();
        bytes32 key = vaultKey(vaultFactory, strategyId, configHash);
        uint256 left = allowance[key];
        if (amount > left) revert AllowanceExceeded();
        allowance[key] = left - amount;
        _send(usdc, vault, amount);
        emit Funded(vault, vaultFactory, strategyId, amount);
    }

    /// Transfer key only: USDT → USDC in this chain's pinned 0.01% pool, paid to this account. The
    /// minimum out is raised to amount × (1 − CONVERSION_BOUND_BP) (decision 30: 1 USD per USDT).
    function convertSwap(uint256 amountIn, uint256 minOut) external nonReentrant returns (uint256 out) {
        _transferKeyOnly();
        (address pool, address usdt, address usdc) = conversionPool();
        if (pool == address(0)) revert ConversionUnavailable();
        uint256 floor = amountIn * (10_000 - CONVERSION_BOUND_BP) / 10_000;
        if (floor == 0 || amountIn > uint256(type(int256).max)) revert BadAmount();
        if (minOut < floor) minOut = floor;
        bool zeroForOne = usdt < usdc; // the pool's token0 is the lower address
        uint256 before = _balanceOf(usdc);
        _swapIn = amountIn;
        IUniswapV3Pool(pool).swap(
            address(this), zeroForOne, int256(amountIn), zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1, ""
        );
        _swapIn = 0;
        out = _balanceOf(usdc) - before;
        if (out < minOut) revert BelowMinimum();
        emit Swapped(amountIn, out);
    }

    /// The pinned pool's callback, during `convertSwap` only: pays it the USDT it is owed, never more
    /// than the swap's amount in.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        (address pool, address usdt, address usdc) = conversionPool();
        uint256 limit = _swapIn;
        if (msg.sender != pool || pool == address(0) || limit == 0) revert NotAllowed();
        int256 owed = usdt < usdc ? amount0Delta : amount1Delta;
        if (owed <= 0 || uint256(owed) > limit) revert BadAmount();
        _swapIn = 0; // one payment per swap
        _send(usdt, pool, uint256(owed));
    }

    /// Transfer key only: burns `amount` of this chain's USDC by CCTP V2 (standard transfer), minted to
    /// THIS same address on another deposit chain; anyone may relay the mint. Its `maxFee` is the
    /// messenger's minimum fee for the amount, read now (0 where the messenger has none), never above
    /// BURN_FEE_CAP_BP of the amount, and the day's fees together never above BURN_FEE_CAP_BP of the
    /// highest USDC balance seen here at a fee-paying burn that day (the partner's audit M3): a round
    /// trip never raises the balance above its earlier peak, so a stolen transfer key's round trips pay
    /// Circle at most that a day here, while a large deposit later in the day is never held back.
    function convertBurn(uint256 amount, uint32 destinationDomain) external nonReentrant {
        _transferKeyOnly();
        (address usdc, uint32 local) = cctpUsdc();
        if (usdc == address(0)) revert ConversionUnavailable();
        if (destinationDomain == local || !_depositDomain(destinationDomain)) revert BadDomain();
        if (amount == 0) revert BadAmount();
        uint256 maxFee = burnMinFee(amount);
        if (maxFee * 10_000 > amount * BURN_FEE_CAP_BP) revert BurnFeeTooHigh();
        if (maxFee != 0) {
            uint256 day = block.timestamp / 1 days;
            if (day != _burnDay) (_burnDay, _burnCap, _burnPaid) = (day, 0, 0);
            uint256 cap = _balanceOf(usdc) * BURN_FEE_CAP_BP / 10_000;
            if (cap > _burnCap) _burnCap = cap;
            if (_burnPaid + maxFee > _burnCap) revert BurnFeeTooHigh();
            _burnPaid += maxFee;
        }
        _approve(usdc, TOKEN_MESSENGER, amount);
        ITokenMessengerV2(TOKEN_MESSENGER).depositForBurn(
            amount, destinationDomain, bytes32(uint256(uint160(address(this)))), usdc, bytes32(0), maxFee, FINALIZED
        );
        _approve(usdc, TOKEN_MESSENGER, 0);
        emit Burned(destinationDomain, amount, maxFee);
    }

    // ── internals ────────────────────────────────────────────────────────────────────────────

    /// An owner's exit fee in `token` (amendment E): `EXIT_FEE` for this chain's USDC and its pinned
    /// USDT, zero for any other token. Never the zero address (the native coin), which is what
    /// `conversionPool()` names as USDT on a chain without one.
    function _exitFee(address token) internal view returns (uint256) {
        if (token == address(0)) return 0;
        (address usdc,) = cctpUsdc();
        (, address usdt,) = conversionPool();
        return token == usdc || token == usdt ? EXIT_FEE : 0;
    }

    /// The owner's exit of `amount` of `token`: its fee, when one is due (a fee token and a fee
    /// recipient), refused unless `amount` is above it (`AmountNotAboveFee`: nothing moves, the money
    /// stays) or is the whole balance (E4b: the last dollar or less leaves free, so the owner always
    /// can), then paid when it can: zero when the transfer reverts or answers false (a blacklisted
    /// recipient), so a fee never blocks the withdrawal it belongs to (amendment E). Returns what it paid.
    function _takeFee(address token, uint256 amount) internal returns (uint256) {
        address recipient = IDepositFactory(factory).feeRecipient();
        uint256 fee = _exitFee(token);
        if (fee == 0 || recipient == address(0)) return 0;
        if (amount <= fee) {
            if (amount == _balanceOf(token)) return 0;
            revert AmountNotAboveFee();
        }
        return _try(token, abi.encodeWithSelector(0xa9059cbb, recipient, fee)) ? fee : 0;
    }

    /// A grant's (factory, domain) is trusted, under the very trust (epoch) the grant was made under.
    function _trustedUnder(Grant storage g) internal view returns (bool) {
        Trust storage t = _trust[trustKey(g.vaultFactory, g.domain)];
        return t.due != 0 && t.epoch == g.trustEpoch && block.timestamp >= t.due;
    }

    function _apply(uint256 id) internal {
        Grant storage g = _grants[id];
        g.applied = true;
        bytes32 key = vaultKey(g.vaultFactory, g.strategyId, g.configHash);
        uint256 remaining = allowance[key] + g.allowance;
        allowance[key] = remaining;
        emit AuthorisationApplied(id, key, g.allowance, remaining);
    }

    function _localAction(bytes32 structHash, uint256 nonce, uint256 deadline, bytes calldata signature) internal {
        if (!synced()) revert NotSynced();
        _settle();
        bytes32 signer = _check(structHash, deadline, signature);
        if (nonce != _localNonce[signer]) revert BadNonce();
        _localNonce[signer] = nonce + 1;
    }

    function _transferKeyOnly() internal view {
        if (msg.sender != IDepositFactory(factory).transferKey() || transferRevoked) revert NotAllowed();
    }

    function _balanceOf(address token) internal view returns (uint256) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSelector(0x70a08231, address(this)));
        if (!ok || ret.length < 32) revert TransferFailed();
        return abi.decode(ret, (uint256));
    }

    /// A token transfer that accepts USDT's missing return value; the native coin for token zero.
    function _send(address token, address to, uint256 amount) internal {
        if (token == address(0)) {
            (bool sent,) = to.call{value: amount}("");
            if (!sent) revert TransferFailed();
            return;
        }
        _call(token, abi.encodeWithSelector(0xa9059cbb, to, amount));
    }

    function _approve(address token, address spender, uint256 amount) internal {
        _call(token, abi.encodeWithSelector(0x095ea7b3, spender, amount));
    }

    function _call(address token, bytes memory data) internal {
        if (!_try(token, data)) revert TransferFailed();
    }

    /// A token call that succeeded: code at `token`, no revert, and no answer or exactly `true` (1)
    /// (USDT's missing return value accepted); never reverts itself.
    function _try(address token, bytes memory data) internal returns (bool) {
        if (token.code.length == 0) return false;
        (bool ok, bytes memory ret) = token.call(data);
        return ok && (ret.length == 0 || (ret.length >= 32 && abi.decode(ret, (uint256)) == 1));
    }
}
