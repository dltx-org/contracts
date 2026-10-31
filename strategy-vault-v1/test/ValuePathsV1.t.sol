// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {FixtureV1} from "./FixtureV1.sol";
import {MockCoreWriter, MockERC20, walletCred} from "./mocks/Mocks.sol";
import {HyperCoreLeg} from "../src/HyperCoreLeg.sol";
import {MemberBase} from "../src/MemberBase.sol";
import {HyperCoreLegExit} from "../src/HyperCoreLegExit.sol";
import {HyperCoreLegExitB} from "../src/HyperCoreLegExitB.sol";
import {HyperCoreLegRoute} from "../src/HyperCoreLegRoute.sol";
import {HyperCoreLegState} from "../src/HyperCoreLegState.sol";
import {HyperCore} from "../src/lib/HyperCore.sol";
import {MemberState} from "../src/MemberState.sol";
import {VaultUpgrade} from "../src/VaultUpgrade.sol";
import {HyperCoreParams, Routes, Sides, StrategySpec} from "../src/Types.sol";
import {OwnerMessages} from "../src/lib/VaultTypes.sol";

/*
 * Every value-moving path of version 1's Hyperliquid leg, pinned to the contract route's table
 * (hyperliquid-contract-route-design.md §5, "Every value-moving path, proved for every external function").
 * These tests pin; they do not drive the code.
 *
 *  1. The selector set. Every selector reachable on a leg proxy is the leg's own ABI, plus what its
 *     `MemberBase.fallback` and `_module` send to a module: VaultUpgrade's seven, exit module A's five,
 *     exit module B's nine, and, as the default, everything the route module holds. The set is read from
 *     the compiler's own method identifiers (`out/`, `fs_permissions` in foundry.toml) and compared with the
 *     table below, in both directions: a new function, or a dropped one, fails until the table here and
 *     §5 are updated together.
 *  2. The execution key. Every `onlyExecution` function is called with adversarial arguments in several
 *     states; every CoreWriter action the leg then recorded is decoded and must be one the key may send:
 *       - 1, an IOC (tif 3) on the strategy's `perp`, or a reduce-only close of a stray DEX 0 perp;
 *       - 7, perp margin to spot;
 *       - 10 and 11, cancels;
 *       - 13, spot USDC to `USDC_SYSTEM` or to the leg itself;
 *       - 9, only the referral setup agent (`setupAgent`, owner-signed `referralSetup`) or a burner
 *         (`endSetup`);
 *     and never 2, 3, 4, 5, 6, 8, 12 (the key never sends a builder approval), 15, 16 or 17.
 */
contract ValuePathsV1Test is FixtureV1 {
    function setUp() public {
        _hyperEvm();
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════════════
    // 1. the selector set
    // ═════════════════════════════════════════════════════════════════════════════════════════════════

    /// The leg's own ABI (`out/HyperCoreLeg.sol`): its functions, `MemberBase`'s and the state's getters.
    /// Every function the execution key may call, here or in a module's table, must also join the key's
    /// barrage below (`_barrage`: `_referralCalls`, `_tradeCalls`, `_moneyCalls`, `_agentCalls`), or what it
    /// sends to CoreWriter is never checked against the key's allowed actions.
    function _legTable() internal pure returns (string[] memory t) {
        t = new string[](110);
        uint256 i;
        // the execution key's (agent or contract route)
        t[i++] = "toMargin(uint256)";
        t[i++] = "fromMargin(uint64)";
        t[i++] = "prime()";
        t[i++] = "topUpHype(uint256)";
        t[i++] = "send(uint8,uint256,bool,uint256)";
        t[i++] = "cancel(uint32,bool,uint128)";
        t[i++] = "proposeAgent(address)";
        t[i++] = "pause(bool)";
        // the owner's signature, the exit's entry, the members' and Circle's messages
        t[i++] = "ownerAction(uint8,address,bytes32,uint256,bytes)";
        t[i++] = "beginExit(uint256,bytes)";
        t[i++] = "beginExitStopped()";
        t[i++] = "notifyLink(uint8)";
        t[i++] = "legExit()";
        t[i++] = "handleReceiveFinalizedMessage(uint32,bytes32,uint32,bytes)";
        t[i++] = "handleReceiveUnfinalizedMessage(uint32,bytes32,uint32,bytes)";
        t[i++] = "receiveLocal(uint256)";
        t[i++] = "exitTransfer(uint256)";
        t[i++] = "announceReady(uint8)";
        t[i++] = "initialize(address,address,address[],uint32[],uint8,bytes32,bytes32,bytes)";
        // the leg standard and views
        t[i++] = "ready(uint8)";
        t[i++] = "legInfo()";
        t[i++] = "paramsType()";
        t[i++] = "MEMBER_TYPE()";
        // public state and constants (getters)
        t[i++] = "CLOSING()";
        t[i++] = "CODE_VERSION()";
        t[i++] = "CORE_DEPOSIT_WALLET()";
        t[i++] = "EXIT_MESSAGE()";
        t[i++] = "HYPE_SYSTEM()";
        t[i++] = "NOT_IN_EXIT()";
        t[i++] = "READY_MESSAGE()";
        t[i++] = "RECOVERED()";
        t[i++] = "RECOVERED_WITH_RESIDUE()";
        t[i++] = "REPORT_MESSAGE()";
        t[i++] = "UPGRADE_MESSAGE()";
        t[i++] = "USDC()";
        t[i++] = "USDC_SYSTEM()";
        t[i++] = "agent()";
        t[i++] = "agentEverSet()";
        t[i++] = "asset()";
        t[i++] = "builder()";
        t[i++] = "builderFeeX10()";
        t[i++] = "burning()";
        t[i++] = "codeVersion()";
        t[i++] = "configHash()";
        t[i++] = "createdAt()";
        t[i++] = "dexSince(uint32)";
        t[i++] = "executionRevoked()";
        t[i++] = "exitAgent()";
        t[i++] = "exitModule()";
        t[i++] = "exitModuleB()";
        t[i++] = "exitStartedAt()";
        t[i++] = "exiting()";
        t[i++] = "factory()";
        t[i++] = "fastFeeCapBp()";
        t[i++] = "feeBudgetBp()";
        t[i++] = "feeDay()";
        t[i++] = "feeToday()";
        t[i++] = "feeYesterday()";
        t[i++] = "feesFrom(uint256)";
        t[i++] = "floor()";
        t[i++] = "floorSet()";
        t[i++] = "group()";
        t[i++] = "growBoundBp()";
        t[i++] = "lastCoreMove()";
        t[i++] = "lastPublishedAt()";
        t[i++] = "lastSent(bytes32)";
        t[i++] = "linkCount()";
        t[i++] = "linkDomains(uint256)";
        t[i++] = "links(uint256)";
        t[i++] = "localLinks()";
        t[i++] = "marginTriedAt()";
        t[i++] = "maxLeverageX100()";
        t[i++] = "memberType()";
        t[i++] = "opCount()";
        t[i++] = "orderBoundBp()";
        t[i++] = "othersPending()";
        t[i++] = "owner()";
        t[i++] = "ownerAgent()";
        t[i++] = "ownerAgentAt()";
        t[i++] = "ownerNonceOf(bytes32)";
        t[i++] = "paused()";
        t[i++] = "pendingAgent()";
        t[i++] = "pendingAgentAt()";
        t[i++] = "pendingBuilder()";
        t[i++] = "pendingBuilderAt()";
        t[i++] = "pendingBuilderFeeX10()";
        t[i++] = "perp()";
        t[i++] = "profile()";
        t[i++] = "purchases()";
        t[i++] = "quarantine()";
        t[i++] = "readyLinks()";
        t[i++] = "receivedFrom(uint256)";
        t[i++] = "receivedFromOthers()";
        t[i++] = "reduceBoundBp()";
        t[i++] = "referralSetup()";
        t[i++] = "registry()";
        t[i++] = "reportSeq()";
        t[i++] = "reserved()";
        t[i++] = "route()";
        t[i++] = "routeModule()";
        t[i++] = "sentTo(uint256)";
        t[i++] = "setupConfirmed()";
        t[i++] = "setupDone()";
        t[i++] = "setupOpen()";
        t[i++] = "setupUntil()";
        t[i++] = "side()";
        t[i++] = "strategyId()";
        t[i++] = "sweepSince(address)";
        t[i++] = "toldPending()";
        t[i++] = "upgradeModule()";
        assert(i == t.length);
    }

    /// Dispatched to exit module A by `HyperCoreLeg._module`.
    function _moduleATable() internal pure returns (string[] memory t) {
        t = new string[](5);
        uint256 i;
        // module A
        t[i++] = "exitStep(((uint32,bool,uint128)[],uint32[],(uint32,uint64)[]))";
        t[i++] = "bridgeOut()";
        t[i++] = "applyOwnerAgent()";
        t[i++] = "applyAgent()";
        t[i++] = "readsClean()";
        assert(i == t.length);
    }

    /// Dispatched to exit module B by `HyperCoreLeg._module`.
    function _moduleBTable() internal pure returns (string[] memory t) {
        t = new string[](9);
        uint256 i;
        // module B
        t[i++] = "ownerOrder(uint32,bool,uint64,uint64,uint8,bytes32,uint256,bytes)";
        t[i++] = "proposeSweep(address)";
        t[i++] = "sweepResidue(uint64,address)";
        t[i++] = "exitStatus()";
        t[i++] = "receiveMint(bytes,bytes)";
        t[i++] = "report()";
        t[i++] = "holdings()";
        t[i++] = "checkProfile((address,uint8,address,address,uint24,bool,bytes32,uint16,address,bytes32,uint32,uint32,bytes32,uint8,bytes32,bytes32,(bytes32,uint8,address,address,uint32)[2]))";
        t[i++] = "validateParams(address,bytes)";
        assert(i == t.length);
    }

    /// Dispatched to the upgrade module by `MemberBase.fallback`.
    function _upgradeTable() internal pure returns (string[] memory t) {
        t = new string[](7);
        uint256 i;
        // VaultUpgrade
        t[i++] = "scheduleUpgrade(bytes32,bytes32,uint256,bytes)";
        t[i++] = "cancelPendingAction(uint8,bytes32,uint256,uint256,bytes)";
        t[i++] = "applyUpgrade()";
        t[i++] = "publishUpgrade(uint8)";
        t[i++] = "followUpgrade(bytes32)";
        t[i++] = "followMessage(bytes32,uint256)";
        t[i++] = "pendingAction()";
        assert(i == t.length);
    }

    /// Everything else goes to the route module (`_module`'s default): its external functions.
    function _routeTable() internal pure returns (string[] memory t) {
        t = new string[](10);
        uint256 i;
        // route
        t[i++] = "order(bool,uint64,bool,uint128)";
        t[i++] = "cancelResting((uint32,bool,uint128)[])";
        t[i++] = "closeStray(uint32)";
        t[i++] = "setBuilderFee(address,uint16,bytes32,uint256,bytes)";
        t[i++] = "applyBuilderFee()";
        t[i++] = "cancelBuilderFee(bytes32,uint256,bytes)";
        t[i++] = "approveBuilder()";
        t[i++] = "setupAgent(address)";
        t[i++] = "endSetup()";
        t[i++] = "routeOwnerAction(uint8,address)";
        assert(i == t.length);
    }

    /// The method identifiers of contract `name`, as signatures, from the compiler's output.
    function _sigs(string memory name) internal view returns (string[] memory) {
        string memory json = vm.readFile(string.concat("out/", name, ".sol/", name, ".json"));
        return vm.parseJsonKeys(json, ".methodIdentifiers");
    }

    function _sel(string memory sig) internal pure returns (bytes4) {
        return bytes4(keccak256(bytes(sig)));
    }

    function _has(string[] memory set, string memory sig) internal pure returns (bool) {
        for (uint256 i; i < set.length; ++i) {
            if (_sel(set[i]) == _sel(sig)) return true;
        }
        return false;
    }

    /// `a` without the members of `b`.
    function _minus(string[] memory a, string[] memory b) internal pure returns (string[] memory out) {
        string[] memory tmp = new string[](a.length);
        uint256 n;
        for (uint256 i; i < a.length; ++i) {
            if (!_has(b, a[i])) tmp[n++] = a[i];
        }
        out = new string[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = tmp[i];
        }
    }

    /// Equal as sets, and no duplicate; a difference is named.
    function _sameSet(string[] memory got, string[] memory want, string memory what) internal pure {
        for (uint256 i; i < got.length; ++i) {
            assertTrue(_has(want, got[i]), string.concat(what, ": not in the table: ", got[i]));
        }
        for (uint256 i; i < want.length; ++i) {
            assertTrue(_has(got, want[i]), string.concat(what, ": in the table, not in the build: ", want[i]));
        }
        assertEq(got.length, want.length, string.concat(what, ": a duplicate"));
    }

    function test_paths_selectorsAreTheSpecsTable() public {
        string[] memory leg = _sigs("HyperCoreLeg");
        // the leg answers its own ABI itself
        _sameSet(leg, _legTable(), "the leg's ABI");
        // each module holds functions the leg does not: exactly the ones the leg sends it
        _sameSet(_minus(_sigs("HyperCoreLegExit"), leg), _moduleATable(), "exit module A");
        _sameSet(_minus(_sigs("HyperCoreLegExitB"), leg), _moduleBTable(), "exit module B");
        _sameSet(_minus(_sigs("VaultUpgrade"), leg), _upgradeTable(), "the upgrade module");
        // the route module's: everything it holds beyond the leg's own ABI is reachable, by default
        _sameSet(_minus(_sigs("HyperCoreLegRoute"), leg), _routeTable(), "the route module");
        // no selector in two places: the reachable set is the sum of the tables
        string[] memory all = new string[](
            _legTable().length + _moduleATable().length + _moduleBTable().length + _upgradeTable().length
                + _routeTable().length
        );
        uint256 n;
        n = _append(all, n, _legTable());
        n = _append(all, n, _moduleATable());
        n = _append(all, n, _moduleBTable());
        n = _append(all, n, _upgradeTable());
        n = _append(all, n, _routeTable());
        for (uint256 i; i < n; ++i) {
            for (uint256 j = i + 1; j < n; ++j) {
                assertTrue(_sel(all[i]) != _sel(all[j]), string.concat("one selector twice: ", all[i]));
            }
        }
        assertEq(n, 110 + 5 + 9 + 7 + 10);
    }

    function _append(string[] memory to, uint256 n, string[] memory from) internal pure returns (uint256) {
        for (uint256 i; i < from.length; ++i) {
            to[n++] = from[i];
        }
        return n;
    }

    /// The table says where each module's selector goes; the proxy does it. A selector the leg does not
    /// name explicitly would reach the route module's fallback and be refused `Unsupported`; the rest of
    /// the world is refused the same way.
    function test_paths_everyTableSelectorIsDispatched() public {
        address l = _contractShort();
        bytes memory unsupported = abi.encodeWithSelector(MemberState.Unsupported.selector);
        (bool ok, bytes memory ret) = l.call(abi.encodeWithSignature("nope()"));
        assertFalse(ok);
        assertEq(ret, unsupported);
        _dispatched(l, _moduleATable());
        _dispatched(l, _moduleBTable());
        _dispatched(l, _upgradeTable());
        _dispatched(l, _routeTable());
        // the modules are run by DELEGATECALL only: called in their own right, they refuse
        (ok, ret) = address(shortRoute).call(abi.encodeWithSignature("nope()"));
        assertEq(ret, unsupported);
    }

    function _dispatched(address l, string[] memory sigs) internal {
        bytes memory unsupported = abi.encodeWithSelector(MemberState.Unsupported.selector);
        for (uint256 i; i < sigs.length; ++i) {
            vm.prank(stranger);
            (bool ok, bytes memory ret) = l.call(abi.encodePacked(_sel(sigs[i])));
            // the upgrade module's four hub-only functions refuse a leg `Unsupported` themselves (`hubOnly`)
            bytes4 s = _sel(sigs[i]);
            bool hubOnly = s == VaultUpgrade.scheduleUpgrade.selector || s == VaultUpgrade.cancelPendingAction.selector
                || s == VaultUpgrade.applyUpgrade.selector || s == VaultUpgrade.publishUpgrade.selector;
            assertTrue(
                ok || hubOnly || keccak256(ret) != keccak256(unsupported), string.concat("not dispatched: ", sigs[i])
            );
        }
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════════════
    // 2. the execution key on the contract route
    // ═════════════════════════════════════════════════════════════════════════════════════════════════

    uint64 constant PX = 1_000_000; // BTC at $100,000 (10^-1 USD, szd 5)
    int64 constant EQUITY = 10_000e6; // $10,000: at 10x, a cap of $100,000
    uint64 constant STEP = 1_000; // one BTC size step (1e-5) in an order's 1e-8
    uint64 constant STRAY_MARK = 1_000_000; // a stray BTC perp (perp 1): mark $100,000
    uint64 constant STRAY_ORACLE = 1_020_000; // its oracle $102,000
    uint32 constant STRAY = 1;
    address constant USDC_SYSTEM = 0x2000000000000000000000000000000000000000;
    address constant SETUP = address(0x5E7);
    address constant BUILDER = address(0xB1);
    address attacker = makeAddr("attacker");

    /// The owner's `CONFIRM_SETUP` in the barrage (spec §16): signed at the start of this round, once the
    /// book is set; the CoreWriter count and Circle's deposits when it was signed.
    uint256 internal confirmRound = type(uint256).max;
    uint256 internal confirmedFrom;
    uint256 internal depositedBefore;

    /// Rows a barrage recorded: who the key made an agent, by `setupAgent`, and by `endSetup`.
    address[] internal setups;
    address[] internal burners;

    /// The money calls first in each round, before the referral calls (the final review's C1: a deposit
    /// sent in the setup's own block); Circle's deposits when a setup agent was named.
    bool internal moneyFirst;
    uint256 internal depositedAtSetup;

    /// A BTC strategy on the contract route (BTC's perp at its real 40x): the short, 10x, a 20 bp growth
    /// band and a 15 bp reduce band inside a 50 bp order bound, no builder fee.
    function _contractShort() internal returns (address) {
        return _contractShortAs(STRATEGY, false, 0);
    }

    /// `builderFee` above 0 signs a builder (`BUILDER`) at that rate: the contract route stores it and never
    /// approves it, so the key's `approveBuilder()` must send no 12.
    function _contractShortAs(bytes32 id, bool referralSetup, uint16 builderFee) internal returns (address) {
        core.setMaxLeverage(0, 40);
        HyperCoreParams memory s = _shortParams(_btc(), btcProfile);
        s.orderBoundBp = 50;
        s.route = Routes.CONTRACT;
        s.side = Sides.SHORT;
        s.maxLeverageX100 = 1000;
        s.growBoundBp = 20;
        s.reduceBoundBp = 15;
        s.referralSetup = referralSetup;
        s.builder = builderFee == 0 ? address(0) : BUILDER;
        s.builderFeeX10 = builderFee;
        StrategySpec memory c = _btcSpec();
        c.legs[1].params = abi.encode(s);
        return _createAs(id, c)[0];
    }

    /// HyperCore priced (the strategy's perp and a stray BTC perp), at block 1,000, the account flat with
    /// `equity` of account value.
    function _world(HyperCoreLeg l, int64 equity) internal {
        core.setL1Block(1_000);
        core.setOracle(0, PX, 5);
        core.setMark(0, PX);
        core.setMaxLeverage(STRAY, 40);
        core.setOracle(STRAY, STRAY_ORACLE, 5);
        core.setMark(STRAY, STRAY_MARK);
        core.setExists(address(l), true);
        core.setMargin(0, address(l), equity, 0, 0);
    }

    /// The book: `own` steps on the strategy's perp, `stray` on perp 1, DEX 0's notional at the marks.
    function _book(HyperCoreLeg l, int64 own, int64 stray, int64 equity) internal {
        core.setPosition(address(l), 0, own);
        core.setPosition(address(l), uint16(STRAY), stray);
        uint64 ntl = uint64(own < 0 ? -own : own) * PX + uint64(stray < 0 ? -stray : stray) * STRAY_MARK;
        core.setMargin(0, address(l), equity, 0, ntl);
    }

    /// The owner's `VaultAction`, signed by the wallet credential, submitted by a stranger.
    function _act(HyperCoreLeg l, uint8 action, address agent) internal {
        bytes32 cred = walletCred(wallet);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _sign(
            walletPk,
            keccak256(
                abi.encode(
                    OwnerMessages.VAULT_ACTION_TYPEHASH, address(l), block.chainid, action, agent, l.ownerNonceOf(cred), deadline
                )
            )
        );
        vm.prank(stranger);
        l.ownerAction(action, agent, cred, deadline, sig);
    }

    function _count() internal view returns (uint256) {
        return MockCoreWriter(CORE_WRITER).count();
    }

    /// The key calls `data` on `l`; whether it went through.
    function _call(address l, bytes memory data) internal returns (bool ok) {
        vm.prank(key);
        (ok,) = l.call(data);
    }

    function _book4(HyperCoreLeg l, uint256 r) internal {
        uint256 k = r % 4;
        if (k == 0) _book(l, 0, -10_000, EQUITY); // flat, a short stray
        else if (k == 1) _book(l, -50_000, 0, EQUITY); // short, no stray
        else if (k == 2) _book(l, 0, 0, EQUITY); // flat, no stray
        else _book(l, 50_000, 10_000, EQUITY); // a long own position and a long stray
    }

    /// `rounds` of the key calling every `onlyExecution` function (and the two that `onlyExecution` guards
    /// for a while, `endSetup`) with arguments an attacker would pick, in a new HyperCore block each round.
    /// `book` 0: the book rotates; 1: the first round as `_setupLeg` left it (a $5 fresh account), flat after.
    function _barrage(HyperCoreLeg l, uint256 book, uint256 rounds) internal {
        address a = address(l);
        for (uint256 r; r < rounds; ++r) {
            core.setL1Block(uint64(1_000 + 3_000 * (r + 1))); // HyperCore's clock only runs forward
            vm.roll(vm.getBlockNumber() + 25);
            vm.warp(vm.getBlockTimestamp() + 90 minutes);
            if (book == 0) _book4(l, r);
            else if (r > 0) _book(l, 0, 0, EQUITY);
            if (r == confirmRound) {
                depositedBefore = MockERC20(HYPER_USDC).balanceOf(CDW);
                confirmedFrom = _count();
                _act(l, OwnerMessages.CONFIRM_SETUP, l.agent());
            }
            MockERC20(HYPER_USDC).mint(a, 100e6);
            vm.deal(a, 1 ether);
            if (moneyFirst) {
                _moneyCalls(l);
                core.setL1Block(core.l1Block() + 1_000);
            }
            _referralCalls(l);
            _tradeCalls(a);
            core.setL1Block(core.l1Block() + 1_000); // the next block: the window of the order above is over
            _moneyCalls(l);
            core.setL1Block(core.l1Block() + 1_000);
            _call(a, abi.encodeCall(HyperCoreLeg.prime, ()));
            _agentCalls(a);
            if (_call(a, abi.encodeCall(HyperCoreLegRoute.endSetup, ()))) burners.push(l.agent());
        }
    }

    function _referralCalls(HyperCoreLeg l) internal {
        address[5] memory who = [address(0), address(1), SETUP, address(l), attacker];
        for (uint256 i; i < who.length; ++i) {
            if (_call(address(l), abi.encodeCall(HyperCoreLegRoute.setupAgent, (who[i])))) {
                setups.push(l.agent());
                depositedAtSetup = MockERC20(HYPER_USDC).balanceOf(CDW);
            }
        }
    }

    function _tradeCalls(address a) internal {
        uint64[8] memory sizes = [uint64(0), 1, STEP, 5 * STEP, 10 * STEP, 12 * STEP, 10_000 * STEP, type(uint64).max];
        uint128[2] memory cloids = [uint128(0), type(uint128).max];
        for (uint256 b; b < 2; ++b) {
            for (uint256 s; s < sizes.length; ++s) {
                for (uint256 ro; ro < 2; ++ro) {
                    for (uint256 c; c < 2; ++c) {
                        _call(a, abi.encodeCall(HyperCoreLegRoute.order, (b == 1, sizes[s], ro == 1, cloids[c])));
                    }
                }
            }
        }
        uint32[7] memory perps = [uint32(0), STRAY, 2, 9_999, 10_000, 110_000, type(uint32).max];
        for (uint256 p; p < perps.length; ++p) {
            _call(a, abi.encodeCall(HyperCoreLegRoute.closeStray, (perps[p])));
        }
        uint32[6] memory assets = [uint32(0), STRAY, 9_999, 10_000, 110_000, type(uint32).max];
        uint128[3] memory ids = [uint128(0), 1, type(uint128).max];
        for (uint256 x; x < assets.length; ++x) {
            for (uint256 y; y < ids.length; ++y) {
                _call(a, abi.encodeCall(HyperCoreLeg.cancel, (assets[x], false, ids[y])));
                _call(a, abi.encodeCall(HyperCoreLeg.cancel, (assets[x], true, ids[y])));
            }
        }
    }

    function _moneyCalls(HyperCoreLeg l) internal {
        address a = address(l);
        uint256[6] memory amounts = [uint256(0), 1, 1e6, 50e6, 100e6, type(uint256).max];
        for (uint256 i; i < amounts.length; ++i) {
            _call(a, abi.encodeCall(HyperCoreLeg.toMargin, (amounts[i])));
            _call(a, abi.encodeCall(HyperCoreLeg.topUpHype, (amounts[i] > 1 ether ? 1 ether : amounts[i])));
        }
        uint64[6] memory margins = [uint64(0), 1, 1e6, 100e6, uint64(1) << 63, type(uint64).max];
        for (uint256 i; i < margins.length; ++i) {
            _call(a, abi.encodeCall(HyperCoreLeg.fromMargin, (margins[i])));
        }
        uint8[4] memory ks = [uint8(0), 1, 2, 255];
        uint256[3] memory sends = [uint256(0), 1e6, type(uint256).max];
        for (uint256 k; k < ks.length; ++k) {
            for (uint256 s; s < sends.length; ++s) {
                for (uint256 f; f < sends.length; ++f) {
                    _call(a, abi.encodeCall(HyperCoreLeg.send, (ks[k], sends[s], f == 1, sends[f])));
                    _call(a, abi.encodeCall(HyperCoreLeg.send, (ks[k], sends[s], f != 1, sends[f])));
                }
            }
        }
    }

    function _agentCalls(address a) internal {
        address[5] memory who = [address(0), address(1), SETUP, attacker, key];
        for (uint256 i; i < who.length; ++i) {
            _call(a, abi.encodeCall(HyperCoreLeg.proposeAgent, (who[i])));
        }
        _call(a, abi.encodeCall(HyperCoreLegExit.applyAgent, ()));
        // anyone's, so the key's too: the builder's approval (the key never sends a nonzero 12) and the
        // clean-up of resting orders
        _call(a, abi.encodeCall(HyperCoreLegRoute.approveBuilder, ()));
        _call(a, abi.encodeCall(HyperCoreLegRoute.applyBuilderFee, ()));
        HyperCoreLegState.Cancel[] memory cs = new HyperCoreLegState.Cancel[](3);
        cs[0] = HyperCoreLegState.Cancel(0, false, 1);
        cs[1] = HyperCoreLegState.Cancel(STRAY, true, type(uint128).max);
        cs[2] = HyperCoreLegState.Cancel(110_000, false, 0);
        _call(a, abi.encodeCall(HyperCoreLegRoute.cancelResting, (cs)));
        // the owner's actions checked in the route module: only the leg calls them on itself, even naming
        // the agent now approved (which the owner's own would name)
        address[6] memory named = [address(0), address(1), SETUP, attacker, key, HyperCoreLeg(payable(a)).agent()];
        for (uint256 i; i < named.length; ++i) {
            _call(a, abi.encodeCall(HyperCoreLegRoute.routeOwnerAction, (OwnerMessages.CONFIRM_SETUP, named[i])));
            _call(a, abi.encodeCall(HyperCoreLegRoute.routeOwnerAction, (OwnerMessages.END_QUARANTINE, named[i])));
        }
        _call(a, abi.encodeCall(MemberBase.pause, (true)));
        _call(a, abi.encodeCall(MemberBase.pause, (false)));
    }

    struct Seen {
        uint256[18] ids; // how many of each CoreWriter action id
        uint256 own; // action 1 on the strategy's perp
        uint256 growth; // ... of which not reduce-only
        uint256 stray; // action 1 on the stray perp
        uint256 setupNames; // action 9 naming a setup agent
        uint256 burnerNames; // action 9 naming a burner
    }

    function _in(address[] storage set, address x) internal view returns (bool) {
        for (uint256 i; i < set.length; ++i) {
            if (set[i] == x) return true;
        }
        return false;
    }

    /// Every action the leg recorded from `from` on is one the key may send (see the file's header).
    function _assertAllowed(HyperCoreLeg l, uint256 from) internal returns (Seen memory s) {
        return _assertAllowedIn(l, from, _count());
    }

    /// `_assertAllowed` over the actions `from` to `to` (excluded).
    function _assertAllowedIn(HyperCoreLeg l, uint256 from, uint256 to) internal returns (Seen memory s) {
        MockCoreWriter w = MockCoreWriter(CORE_WRITER);
        uint32 perp = l.perp();
        for (uint256 i = from; i < to; ++i) {
            MockCoreWriter.Action memory act = w.action(i);
            assertEq(act.user, address(l), "sent by the leg");
            bytes memory d = act.data;
            assertEq(uint8(d[0]), 1, "action version");
            uint256 id = uint256(uint8(d[1])) << 16 | uint256(uint8(d[2])) << 8 | uint256(uint8(d[3]));
            bytes memory body = new bytes(d.length - 4);
            for (uint256 j; j < body.length; ++j) {
                body[j] = d[j + 4];
            }
            assertTrue(id < 18, "an unknown action id");
            s.ids[id]++;
            if (id == 1) {
                (uint32 asset, bool isBuy,, uint64 sz, bool ro, uint8 tif, uint128 cloid) =
                    abi.decode(body, (uint32, bool, uint64, uint64, bool, uint8, uint128));
                assertEq(uint256(tif), 3, "IOC only");
                assertGt(sz, 0, "something to trade");
                if (asset == perp) {
                    s.own++;
                    if (!ro) {
                        s.growth++;
                        assertFalse(isBuy, "growth only on the signed side (a short)");
                    }
                } else {
                    assertEq(asset, STRAY, "a stray perp, nothing else");
                    assertTrue(ro, "a stray is only closed");
                    assertEq(cloid, 0);
                    s.stray++;
                }
            } else if (id == 7) {
                (, bool toPerp) = abi.decode(body, (uint64, bool));
                assertFalse(toPerp, "margin only leaves for spot");
            } else if (id == 10 || id == 11) {
                abi.decode(body, (uint256, uint256));
            } else if (id == 13) {
                (address to, address sub, uint32 src, uint32 dst, uint64 token, uint64 amount) =
                    abi.decode(body, (address, address, uint32, uint32, uint64, uint64));
                assertTrue(to == USDC_SYSTEM || to == address(l), "spot USDC to the leg only");
                assertEq(sub, address(0));
                assertEq(src, type(uint32).max, "spot to spot");
                assertEq(dst, type(uint32).max);
                assertEq(token, 0, "USDC");
                amount; // 0 is harmless: `fromMargin(0)` sends a spot-to-spot of nothing
            } else if (id == 9) {
                (address named,) = abi.decode(body, (address, string));
                if (_in(burners, named)) s.burnerNames++;
                else if (_in(setups, named)) s.setupNames++;
                else assertTrue(false, "an agent the key named outside the referral setup and a burner");
                assertTrue(named != attacker && named != key, "never the attacker's");
            } else {
                // 2, 3, 4, 5, 6, 8, 12, 15, 16, 17 (and 0, 14): never sent by the key
                assertTrue(false, string.concat("a CoreWriter action the key never sends: ", vm.toString(id)));
            }
        }
        assertLe(s.setupNames, 1, "the referral setup runs once");
        assertLe(setups.length, 1);
        // nothing the key did reached the attacker, in USDC or HYPE
        assertEq(MockERC20(HYPER_USDC).balanceOf(attacker), 0);
        assertEq(attacker.balance, 0);
    }

    /// Flat, rotating books, a stray perp: every `onlyExecution` function, adversarially, in a world
    /// where most of them work.
    function test_paths_executionKeyOnContractRoute() public {
        HyperCoreLeg l = HyperCoreLeg(payable(_contractShortAs(STRATEGY, false, 10)));
        assertEq(l.builderFeeX10(), 10); // signed, stored, never approved on this route
        _world(l, EQUITY);
        uint256 from = _count();
        _barrage(l, 0, 8);
        Seen memory s = _assertAllowed(l, from);
        // the barrage reached each allowed action (a vacuous pass would pin nothing)
        assertGt(s.own, 0, "orders on the strategy's perp");
        assertGt(s.growth, 0, "growth");
        assertGt(s.stray, 0, "a stray closed");
        assertGt(s.ids[7], 0, "margin to spot");
        assertGt(s.ids[10], 0, "cancels by oid");
        assertGt(s.ids[11], 0, "cancels by cloid");
        assertGt(s.ids[13], 0, "spot USDC to the leg");
        // no referral setup was signed: no agent at all
        assertEq(s.ids[9], 0, "the key names no agent on a strategy without a referral setup");
        assertEq(s.ids[12], 0, "the key never approves a builder, at the signed 1 bp or any rate");
        assertEq(l.pendingAgent(), address(0));
        assertEq(uint256(uint160(l.ownerAgent())), 0);
    }

    /// Quarantine, after the owner's switch from the agent route: the key may only reduce, cancel and close
    /// strays; no growth, no margin out, no agent.
    function test_paths_executionKeyInQuarantine() public {
        core.setMaxLeverage(0, 40);
        HyperCoreLeg l = HyperCoreLeg(payable(_createAs(keccak256("quarantine"), _btcSpec())[0]));
        _world(l, EQUITY);
        vm.prank(key);
        l.proposeAgent(address(0xA6E));
        vm.prank(key);
        HyperCoreLegExit(address(l)).applyAgent();
        _act(l, OwnerMessages.USE_CONTRACT, address(0));
        assertTrue(l.quarantine());
        uint256 from = _count();
        _barrage(l, 0, 8);
        Seen memory s = _assertAllowed(l, from);
        assertEq(s.growth, 0, "no growth in quarantine");
        assertGt(s.own, 0, "reductions");
        assertGt(s.stray, 0, "a stray closed");
        assertEq(s.ids[7], 0, "no margin out in quarantine");
        assertEq(s.ids[13], 0);
        assertEq(s.ids[9], 0, "no agent");
        assertGt(s.ids[10] + s.ids[11], 0, "cancels");
    }

    /// The referral setup: the owner signed `referralSetup`, the account is a fresh $5. The key names one
    /// setup agent, once, and then only burners; no money joins and no growth is sent until the owner's
    /// `CONFIRM_SETUP` (spec §16), signed here in round 2, a round after the setup ended.
    function test_paths_executionKeyDuringTheReferralSetup() public {
        HyperCoreLeg l = HyperCoreLeg(payable(_contractShortAs(keccak256("setup"), true, 0)));
        _world(l, 5e6);
        core.setSpot(address(l), 0, 5e8);
        uint256 from = _count();
        uint256 deposited = MockERC20(HYPER_USDC).balanceOf(CDW);
        confirmRound = 2;
        _barrage(l, 1, 6);
        Seen memory s = _assertAllowed(l, from);
        assertEq(s.setupNames, 1, "one setup agent");
        assertGt(s.burnerNames, 0, "then burners");
        assertEq(s.ids[9], s.setupNames + s.burnerNames);
        assertTrue(l.setupDone());
        assertFalse(l.setupOpen());
        assertTrue(l.setupConfirmed());
        assertEq(setups[0], SETUP, "the setup agent the key chose");
        assertLe(depositedAtSetup - deposited, 5e6, "at most $5 before the setup agent");
        assertEq(s.ids[12], 0);
        // before the owner's confirm (the setup agent standing, then ended): no money, no growth
        Seen memory before = _assertAllowedIn(l, from, confirmedFrom);
        assertGt(before.burnerNames, 0, "the setup ended before the confirm");
        assertEq(before.growth, 0, "no growth before the confirm");
        assertEq(depositedBefore, deposited, "no money joined before the confirm");
        // from it on, both
        Seen memory afterConfirm = _assertAllowedIn(l, confirmedFrom, _count());
        assertGt(afterConfirm.growth, 0, "growth resumes after the confirm");
        assertGt(MockERC20(HYPER_USDC).balanceOf(CDW), depositedBefore, "money joins after the confirm");
    }

    /// The key's money first, in the same blocks as its referral calls (the final review's C1): HyperCore's
    /// reads never show a deposit sent in the block, so the precompiles alone would let the setup agent
    /// stand over it. Whenever a setup agent was named, at most $5 had joined the account before it; here
    /// the key sent more, so the setup never ran, and the money was never held.
    function test_paths_moneyBeforeTheReferralSetup() public {
        HyperCoreLeg l = HyperCoreLeg(payable(_contractShortAs(keccak256("money first"), true, 0)));
        _world(l, 5e6);
        core.setSpot(address(l), 0, 5e8);
        uint256 from = _count();
        uint256 deposited = MockERC20(HYPER_USDC).balanceOf(CDW);
        moneyFirst = true;
        _barrage(l, 1, 4);
        Seen memory s = _assertAllowed(l, from);
        if (setups.length != 0) assertLe(depositedAtSetup - deposited, 5e6, "no money before the setup agent");
        assertEq(s.setupNames, 0, "no setup agent over the key's money");
        assertFalse(l.setupDone());
        assertGt(MockERC20(HYPER_USDC).balanceOf(CDW) - deposited, 5e6, "the key's money went, never held");
    }

    // ═════════════════════════════════════════════════════════════════════════════════════════════════
    // 3. a close is banded by the owner's signed bound when it is under the perp's ceiling
    // ═════════════════════════════════════════════════════════════════════════════════════════════════

    function _sent() internal view returns (uint32 asset, bool isBuy, uint64 px, uint64 sz, bool ro, uint8 tif, uint128 cloid) {
        return MockCoreWriter(CORE_WRITER).lastOrder();
    }

    /// `_routeParams` signs `orderBoundBp` 50, under BTC's 40x ceiling of 57 bp: the exit's close is priced
    /// at 50, from the stricter of the oracle and the mark, not at the ceiling and not at the 15 bp reduce
    /// band. A `_perpLimit` that took the ceiling alone (dropping the `min`) would price it at 57.
    function test_paths_exitCloseHonoursSignedBandBelowCeiling() public {
        HyperCoreLeg l = HyperCoreLeg(payable(_contractShort()));
        assertEq(l.orderBoundBp(), 50);
        _world(l, EQUITY);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        l.beginExit(deadline, _beginExitSig(deadline));
        // a short of 1 BTC: the close is a buy, a ceiling over the lower of the oracle and the mark
        core.setPosition(address(l), 0, -100_000);
        core.setMargin(0, address(l), EQUITY, 0, 100_000 * PX);
        HyperCoreLegState.ExitArgs memory a;
        vm.prank(stranger);
        HyperCoreLegExit(address(l)).exitStep(a);
        (uint32 asset, bool isBuy, uint64 px, uint64 sz, bool ro,,) = _sent();
        assertEq(asset, 0);
        assertTrue(isBuy);
        assertTrue(ro);
        assertEq(sz, 100_000 * STEP);
        assertEq(px, HyperCore.boundedPx(uint256(PX) * 1e7, 50, true, 1), "at the signed 50 bp");
        assertLt(px, HyperCore.boundedPx(uint256(PX) * 1e7, 57, true, 1), "under the ceiling's");
        assertGt(px, HyperCore.boundedPx(uint256(PX) * 1e7, 15, true, 1), "not the reduce band's");
        // a long, the oracle over the mark: a sale's floor from the higher, the oracle, still at 50 bp
        core.setPosition(address(l), 0, 100_000);
        core.setOracle(0, PX * 101 / 100, 5);
        vm.roll(vm.getBlockNumber() + 20);
        vm.prank(stranger);
        HyperCoreLegExit(address(l)).exitStep(a);
        (, isBuy, px,,,,) = _sent();
        assertFalse(isBuy);
        assertEq(px, HyperCore.boundedPx(uint256(PX) * 101 / 100 * 1e7, 50, false, 1), "a sale: from the higher, at 50 bp");
        assertGt(px, HyperCore.boundedPx(uint256(PX) * 101 / 100 * 1e7, 57, false, 1), "above the ceiling's floor");
    }

    /// The agent route's reduce-only `order` is priced by the same `_perpLimit`: a signed 50 bp, under the
    /// ceiling, is 50.
    function test_paths_agentRouteOrderHonoursSignedBandBelowCeiling() public {
        core.setMaxLeverage(0, 40);
        HyperCoreParams memory s = _shortParams(_btc(), btcProfile);
        s.orderBoundBp = 50;
        StrategySpec memory c = _btcSpec();
        c.legs[1].params = abi.encode(s);
        HyperCoreLeg l = HyperCoreLeg(payable(_createAs(keccak256("agent 50"), c)[0]));
        _world(l, EQUITY);
        vm.prank(key);
        l.proposeAgent(address(0xA6E));
        vm.prank(key);
        HyperCoreLegExit(address(l)).applyAgent();
        assertEq(l.orderBoundBp(), 50);
        vm.prank(key);
        HyperCoreLegRoute(address(l)).order(true, 1_000 * STEP, true, 5);
        (,, uint64 px,,,,) = _sent();
        assertEq(px, HyperCore.boundedPx(uint256(PX) * 1e7, 50, true, 1), "at the signed 50 bp");
        assertLt(px, HyperCore.boundedPx(uint256(PX) * 1e7, 57, true, 1));
    }
}
