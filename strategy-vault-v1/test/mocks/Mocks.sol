// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Credential} from "../../src/interfaces/IDepositOwner.sol";

/*
 * Test doubles. Everything here is test-only; nothing is deployed.
 */

/// The owner: slice 1a's `DepositAccount` reduced to what a vault asks, with its WALLET signature format
/// (0x01 ‖ r ‖ s ‖ v, ECDSA over the digest) and its domain ("DLTX Owner", "1", this address, no chain).
/// The deposit account's credential id of a wallet credential (`credentialId`, `_walletId`): the key of a
/// member's per-credential owner nonce (`ownerNonceOf`, the combined review's CR-E1).
function walletCred(address w) pure returns (bytes32) {
    return keccak256(abi.encode(uint8(1), bytes32(uint256(uint160(w))), bytes32(0)));
}

contract MockOwner {
    mapping(address => bool) public wallets;
    address public withdrawalAddress;
    bool public unsynced; // slice 1a: a copy trusts nothing until the home's record arrives

    function setSynced(bool s) external {
        unsynced = !s;
    }

    function synced() external view returns (bool) {
        return !unsynced;
    }

    function setWallet(address w, bool on) external {
        wallets[w] = on;
        walletOf[walletCred(w)] = w;
    }

    function setWithdrawalAddress(address w) external {
        withdrawalAddress = w;
    }

    function checkOwnerSignature(bytes32 digest, bytes calldata sig) external view returns (bool) {
        if (sig.length != 66 || uint8(sig[0]) != 1) return false;
        if (unsynced) return false;
        (address rec, ECDSA.RecoverError err,) = ECDSA.tryRecoverCalldata(digest, sig[1:]);
        return err == ECDSA.RecoverError.NoError && wallets[rec];
    }

    function isCredential(Credential calldata c) external view returns (bool) {
        return !unsynced && c.kind == 1 && c.y == bytes32(0) && wallets[address(uint160(uint256(c.x)))];
    }

    /// A wallet's id (`walletCred`) only, as `isCredential`.
    mapping(bytes32 => address) public walletOf;

    function isCredentialId(bytes32 id) external view returns (bool) {
        address w = walletOf[id];
        return !unsynced && w != address(0) && wallets[w];
    }

    /// Version 1's frame (owner-upgrades-design.md §C4): a credential's removal proposed, not settled.
    mapping(bytes32 => bool) public removalPendingOf;

    function setRemovalPending(bytes32 id, bool on) external {
        removalPendingOf[id] = on;
    }

    function domainSeparator() external view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,address verifyingContract)"),
                keccak256("DLTX Owner"),
                keccak256("1"),
                address(this)
            )
        );
    }
}

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public frozen; // USDC's issuer blocks an address: every transfer to it reverts

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    /// A token-level event the holder didn't cause (amendment 2b §3.3: a balance below `booked`).
    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
    }

    function setFrozen(address a, bool f) external {
        frozen[a] = f;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(!frozen[to], "frozen");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(!frozen[to], "frozen");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// Circle's MessageTransmitterV2, etched at its address: `localDomain`, a pausable `sendMessage` that
/// records, and `deliver` to play a relayed message into a recipient's handler.
contract MockTransmitter {
    uint32 public localDomain;
    bool public paused;

    struct Sent {
        uint32 destinationDomain;
        bytes32 recipient;
        bytes32 destinationCaller;
        uint32 minFinalityThreshold;
        bytes body;
        address sender;
    }

    Sent[] internal _sent;

    function setLocalDomain(uint32 d) external {
        localDomain = d;
    }

    function setPaused(bool p) external {
        paused = p;
    }

    function sendMessage(uint32 d, bytes32 r, bytes32 c, uint32 f, bytes calldata body) external {
        require(!paused, "Pausable: paused");
        _sent.push(Sent(d, r, c, f, body, msg.sender));
    }

    function sentCount() external view returns (uint256) {
        return _sent.length;
    }

    function sent(uint256 i) external view returns (Sent memory) {
        return _sent[i];
    }

    mapping(bytes32 => bool) public usedNonces;

    /// Circle's relay of a burn's mint (CCTP V2's layout: a 148-byte header, then BurnMessageV2): checks
    /// this chain as the destination, the destination caller, the nonce; mints `amount − feeExecuted` of
    /// the etched USDC to the mint recipient. No attestation is checked: the test plays Circle.
    function receiveMessage(bytes calldata message, bytes calldata) external returns (bool) {
        require(uint32(bytes4(message[8:12])) == localDomain, "Invalid destination domain");
        bytes32 caller = bytes32(message[108:140]);
        require(caller == bytes32(0) || caller == bytes32(uint256(uint160(msg.sender))), "Invalid caller for message");
        bytes32 nonce = bytes32(message[12:44]);
        require(!usedNonces[nonce], "Nonce already used");
        usedNonces[nonce] = true;
        address to = address(uint160(uint256(bytes32(message[184:216]))));
        uint256 amount = uint256(bytes32(message[216:248]));
        uint256 fee = uint256(bytes32(message[312:344]));
        MockERC20(0xb88339CB7199b77E23DB6E890353E22632Ba630f).mint(to, amount - fee);
        return true;
    }

    function deliver(address recipient, uint32 sourceDomain, bytes32 sender, bytes calldata body) external returns (bool) {
        return IHandler(recipient).handleReceiveFinalizedMessage(sourceDomain, sender, 2000, body);
    }
}

interface IHandler {
    function handleReceiveFinalizedMessage(uint32, bytes32, uint32, bytes calldata) external returns (bool);
}

/// Circle's TokenMessengerV2, etched: pulls the burn and records it; pausable.
contract MockTokenMessenger {
    bool public paused;
    uint256 public minFeeBp;

    function setMinFeeBp(uint256 bp) external {
        minFeeBp = bp;
    }

    /// Circle's: `amount × minFee / 1e7`, here in bp.
    function getMinFeeAmount(uint256 amount) external view returns (uint256) {
        return amount * minFeeBp / 10_000;
    }

    struct Burn {
        uint256 amount;
        uint32 destinationDomain;
        bytes32 mintRecipient;
        address burnToken;
        bytes32 destinationCaller;
        uint256 maxFee;
        uint32 minFinalityThreshold;
        address from;
    }

    Burn[] internal _burns;

    function setPaused(bool p) external {
        paused = p;
    }

    function depositForBurn(uint256 a, uint32 d, bytes32 r, address t, bytes32 c, uint256 f, uint32 m) external {
        require(!paused, "Pausable: paused");
        require(f >= a * minFeeBp / 10_000, "Insufficient max fee");
        MockERC20(t).transferFrom(msg.sender, address(this), a);
        _burns.push(Burn(a, d, r, t, c, f, m, msg.sender));
    }

    function burnCount() external view returns (uint256) {
        return _burns.length;
    }

    function burn(uint256 i) external view returns (Burn memory) {
        return _burns[i];
    }
}

/// Circle's CoreDepositWallet, etched: pulls the deposit and records it.
contract MockCoreDepositWallet {
    address public constant USDC = 0xb88339CB7199b77E23DB6E890353E22632Ba630f;
    uint256 public lastAmount;
    uint32 public lastDex;
    address public lastFrom;

    function deposit(uint256 amount, uint32 dex) external {
        MockERC20(USDC).transferFrom(msg.sender, address(this), amount);
        lastAmount = amount;
        lastDex = dex;
        lastFrom = msg.sender;
    }
}

/// CoreWriter, etched at 0x3333…3333: logs every action as the real one does, and keeps them.
contract MockCoreWriter {
    event RawAction(address indexed user, bytes data);

    struct Action {
        address user;
        bytes data;
    }

    Action[] internal _actions;

    // HyperCore's first-transfer fee, played on `CoreState` when a test turns it on (the first-fee run,
    // spec §5): an account's first outgoing transfer pays `firstFee` USDC from spot on top of its amount,
    // once across CoreWriter 6 and 13; an action that can't pay amount + fee is dropped silently. Played:
    // the spot → HyperEVM USDC send (13), the spot send (6), and perp → spot (7: withdrawable to spot in
    // standard mode, nothing in `unified`, where spot is the whole balance). Only 6 and 13 count in
    // `landed` and `dropped`; the test credits HyperEVM itself.
    address internal constant STATE = 0x00000000000000000000000000000000c0eC0dE0;
    address internal constant USDC_SYSTEM = 0x2000000000000000000000000000000000000000;
    bool public playing;
    uint64 public firstFee;
    mapping(address => bool) public feePaid;
    bool public unified;
    uint256 public landed;
    uint256 public dropped;

    function playFirstFee(uint64 fee) external {
        playing = true;
        firstFee = fee;
    }

    function setUnified(bool u) external {
        unified = u;
    }

    /// The account paid its fee before (`prime`, at custody creation).
    function setFeePaid(address u, bool p) external {
        feePaid[u] = p;
    }

    function sendRawAction(bytes calldata data) external {
        _actions.push(Action(msg.sender, data));
        emit RawAction(msg.sender, data);
        if (playing) _play(msg.sender, data);
    }

    function _play(address u, bytes calldata data) internal {
        uint24 id = uint24(bytes3(data[1:4]));
        CoreState st = CoreState(STATE);
        if (id == 7) {
            (uint64 ntl, bool toPerp) = abi.decode(data[4:], (uint64, bool));
            uint64 wd = st.withdrawableOf(u);
            if (unified || toPerp || ntl > wd) return;
            st.setWithdrawable(u, wd - ntl);
            st.setSpot(u, 0, st.spot(u, 0) + ntl * 100);
            return;
        }
        uint64 fee = feePaid[u] ? 0 : firstFee;
        uint64 usdc = st.spot(u, 0) - st.hold(u, 0);
        uint64 token;
        uint64 amount;
        if (id == 13) {
            address to;
            uint32 src;
            uint32 dst;
            (to,, src, dst, token, amount) =
                abi.decode(data[4:], (address, address, uint32, uint32, uint64, uint64));
            if (to != USDC_SYSTEM || src != type(uint32).max || dst != type(uint32).max || token != 0) return;
        } else if (id == 6) {
            (, token, amount) = abi.decode(data[4:], (address, uint64, uint64));
        } else {
            return;
        }
        bool fits = token == 0
            ? uint256(amount) + fee <= usdc
            : amount <= st.spot(u, token) - st.hold(u, token) && fee <= usdc;
        if (!fits) {
            dropped++;
            return;
        }
        st.setSpot(u, token, st.spot(u, token) - amount);
        st.setSpot(u, 0, st.spot(u, 0) - fee);
        feePaid[u] = true;
        landed++;
    }

    function count() external view returns (uint256) {
        return _actions.length;
    }

    function action(uint256 i) external view returns (Action memory) {
        return _actions[i];
    }
}

/// HyperCore's state as the read precompiles show it. Each precompile address is etched with
/// `PrecompileStub`, which forwards its raw input here with its own address.
contract CoreState {
    struct Position {
        int64 szi;
        uint64 entryNtl;
        int64 isolatedRawUsd;
        uint32 leverage;
        bool isIsolated;
    }

    struct Margin {
        int64 accountValue;
        uint64 marginUsed;
        uint64 ntlPos;
        int64 rawUsd;
    }

    struct PerpAssetInfo {
        string coin;
        uint32 marginTableId;
        uint8 szDecimals;
        uint8 maxLeverage;
        bool onlyIsolated;
    }

    struct SpotInfo {
        string name;
        uint64[2] tokens;
    }

    mapping(address => mapping(uint16 => Position)) public positions;
    mapping(address => mapping(uint64 => uint64)) public spot;
    mapping(address => mapping(uint64 => uint64)) public hold;
    mapping(address => uint64) public withdrawableOf;
    mapping(uint32 => uint64) public oracle;
    /// The mark (0x806); zero unless set, so `setMargin`'s `rawUsd = accountValue` keeps the identity
    /// `accountValue = rawUsd + szi × mark` for a test that never sets one.
    mapping(uint32 => uint64) public mark;
    mapping(uint32 => uint8) public szDecimals;
    mapping(uint32 => uint64) public spotBaseOf;
    mapping(uint32 => uint64[2]) public bboOf;
    mapping(uint32 => mapping(address => Margin)) public margins;
    mapping(uint32 => bool) public dexRefused;
    mapping(uint32 => bool) public bboRefused;
    mapping(address => bool) public exists;
    mapping(uint32 => string) public coinOf; // a perp's `coin` ("X" unless set)

    function setCoin(uint32 p, string calldata coin) external {
        coinOf[p] = coin;
    }

    function setPosition(address u, uint16 p, int64 szi) external {
        positions[u][p].szi = szi;
    }

    function setSpot(address u, uint64 t, uint64 total) external {
        spot[u][t] = total;
    }

    function setHold(address u, uint64 t, uint64 h) external {
        hold[u][t] = h;
    }

    function setWithdrawable(address u, uint64 w) external {
        withdrawableOf[u] = w;
    }

    function setMark(uint32 p, uint64 px) external {
        mark[p] = px;
    }

    function setOracle(uint32 p, uint64 px, uint8 szd) external {
        oracle[p] = px;
        szDecimals[p] = szd;
    }

    function setSpotBase(uint32 s, uint64 t) external {
        spotBaseOf[s] = t;
    }

    function setBbo(uint32 a, uint64 bid, uint64 ask) external {
        bboOf[a] = [bid, ask];
    }

    function setBboRefused(uint32 a, bool r) external {
        bboRefused[a] = r;
    }

    function setMargin(uint32 dex, address u, int64 av, uint64 used, uint64 ntl) external {
        margins[dex][u] = Margin(av, used, ntl, av);
    }

    /// A summary whose `rawUsd` differs from its account value (open positions: av = rawUsd + Σ szi × mark).
    function setMarginRaw(uint32 dex, address u, int64 av, uint64 used, uint64 ntl, int64 raw) external {
        margins[dex][u] = Margin(av, used, ntl, raw);
    }

    function setDexRefused(uint32 dex, bool r) external {
        dexRefused[dex] = r;
    }

    function setExists(address u, bool e) external {
        exists[u] = e;
    }

    function answer(address px, bytes calldata input) external view returns (bool ok, bytes memory out) {
        uint256 id = uint160(px);
        if (id == 0x800) {
            (address u, uint16 p) = abi.decode(input, (address, uint16));
            return (true, abi.encode(positions[u][p]));
        }
        if (id == 0x801) {
            (address u, uint64 t) = abi.decode(input, (address, uint64));
            return (true, abi.encode(spot[u][t], hold[u][t], uint64(0)));
        }
        if (id == 0x803) return (true, abi.encode(withdrawableOf[abi.decode(input, (address))]));
        if (id == 0x806) return (true, abi.encode(mark[abi.decode(input, (uint32))]));
        if (id == 0x807) return (true, abi.encode(oracle[abi.decode(input, (uint32))]));
        if (id == 0x80a) {
            uint32 p = abi.decode(input, (uint32));
            if (p >= 100_000) return (false, "");
            string memory coin = bytes(coinOf[p]).length == 0 ? "X" : coinOf[p];
            return (true, abi.encode(PerpAssetInfo(coin, 0, szDecimals[p], 25, false)));
        }
        if (id == 0x80b) {
            uint32 s = abi.decode(input, (uint32));
            return (true, abi.encode(SpotInfo("S", [spotBaseOf[s], uint64(0)])));
        }
        if (id == 0x80e) {
            uint32 a = abi.decode(input, (uint32));
            if (bboRefused[a]) return (false, "");
            return (true, abi.encode(bboOf[a][0], bboOf[a][1]));
        }
        if (id == 0x80f) {
            (uint32 dex, address u) = abi.decode(input, (uint32, address));
            if (dexRefused[dex]) return (false, "");
            return (true, abi.encode(margins[dex][u]));
        }
        if (id == 0x810) return (true, abi.encode(exists[abi.decode(input, (address))]));
        return (false, "");
    }
}

/// Etched at each precompile address: answers from `CoreState` at a fixed address.
contract PrecompileStub {
    address internal constant STATE = 0x00000000000000000000000000000000c0eC0dE0;

    fallback(bytes calldata input) external returns (bytes memory) {
        (bool ok, bytes memory out) = CoreState(STATE).answer(address(this), input);
        if (!ok) revert("precompile error");
        return out;
    }
}

/// CoreWriter at the real one's cost: it only logs (for the gas measurement).
contract LogOnlyCoreWriter {
    event RawAction(address indexed user, bytes data);

    function sendRawAction(bytes calldata data) external {
        emit RawAction(msg.sender, data);
    }
}
