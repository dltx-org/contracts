// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {walletCred} from "./mocks/Mocks.sol";

import {Fixture} from "./utils/Fixture.sol";
import {VaultBase, VaultState} from "../src/VaultBase.sol";
import {LongVault} from "../src/LongVault.sol";
import {LongVaultExit} from "../src/LongVaultExit.sol";
import {ShortVault} from "../src/ShortVault.sol";
import {ShortVaultExit} from "../src/ShortVaultExit.sol";
import {ShortVaultState} from "../src/ShortVaultState.sol";
import {StrategyConfig} from "../src/lib/VaultTypes.sol";

/// HyperEVM's USDC replaced by a token that calls back into the vault while Circle pulls a burn, and
/// records what the call-back got.
contract ReentrantUSDC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public target;
    bytes public data;
    bool public tried;
    bytes public reverted;

    function arm(address t, bytes calldata d) external {
        target = t;
        data = d;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (target != address(0) && !tried) {
            tried = true;
            (bool ok, bytes memory ret) = target.call(data);
            if (!ok) reverted = ret;
        }
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// The exit modules (amendment 2a §3.8): fixed in each leg code's constructor by address and code hash;
/// only the exit's selectors (and, for size, `receiveMint` and `report`) dispatched; run only inside an
/// initialized leg. The hub has none: its fallback refuses everything. The storage layouts are
/// compared by `test.mjs` (`forge inspect … storageLayout`), before any test.
contract ExitModulesTest is Fixture {
    function setUp() public {
        _world();
    }

    function test_legCodes_nameTheirModules() public view {
        assertEq(longCode.exitModule(), address(longExit));
        assertEq(shortCode.exitModule(), address(shortExit));
    }

    function test_constructor_refusesAModuleOtherThanTheOneNamed() public {
        bytes32 h = address(shortExit).codehash;
        vm.expectRevert(VaultBase.BadModule.selector);
        new ShortVault(address(shortExit), keccak256("other"));
        vm.expectRevert(VaultBase.BadModule.selector);
        new ShortVault(address(longExit), h);
        vm.expectRevert(VaultBase.BadModule.selector);
        new ShortVault(stranger, keccak256("")); // no code there
        vm.expectRevert(VaultBase.BadModule.selector);
        new LongVault(address(longExit), bytes32(0));
    }

    /// Called directly, a module's functions act on nothing: its own storage holds the sentinel.
    function test_modules_refuseDirectCalls() public {
        ShortVaultState.ExitArgs memory a;
        vm.expectRevert(VaultState.NotAllowed.selector);
        shortExit.exitStep(a);
        vm.expectRevert(VaultState.NotAllowed.selector);
        shortExit.exitStatus();
        vm.expectRevert(VaultState.NotAllowed.selector);
        shortExit.bridgeOut();
        vm.expectRevert(VaultState.NotAllowed.selector);
        shortExit.proposeSweep(stranger);
        vm.expectRevert(VaultState.NotAllowed.selector);
        shortExit.sweepResidue(150, stranger);
        vm.expectRevert(VaultState.NotAllowed.selector);
        shortExit.ownerOrder(1, true, 1, 1, 4, walletCred(wallet), block.timestamp, "");
        vm.expectRevert(VaultState.NotAllowed.selector);
        shortExit.receiveMint("", "");
        vm.expectRevert(VaultState.NotAllowed.selector);
        shortExit.report();
        vm.expectRevert(VaultState.NotAllowed.selector);
        longExit.exitStep(0, 0);
        vm.expectRevert(VaultState.NotAllowed.selector);
        longExit.exitPart(1, 0);
        vm.expectRevert(VaultState.NotAllowed.selector);
        longExit.receiveMint("", "");
        vm.expectRevert(VaultState.NotAllowed.selector);
        longExit.report();
    }

    /// The hub's module is its fee module (amendment 2b): a leg's selector never falls through.
    function test_hub_onlyItsFeeModule() public {
        assertEq(hubCode.exitModule(), address(hubFee));
        transmitter.setLocalDomain(ARB_DOMAIN);
        address hub = _create(_config());
        (bool ok, bytes memory ret) = hub.call(abi.encodeCall(ShortVaultExit.report, ()));
        assertFalse(ok);
        assertEq(bytes4(ret), VaultState.Unsupported.selector);
        (ok, ret) = hub.call(abi.encodeCall(LongVaultExit.exitPart, (1, 0)));
        assertFalse(ok);
        assertEq(bytes4(ret), VaultState.Unsupported.selector);
    }

    /// Through a leg code that was never initialized (the code itself), the same.
    function test_legCodes_refuseTheExitThroughThemselves() public {
        vm.expectRevert(VaultState.NotAllowed.selector);
        ShortVaultExit(address(shortCode)).exitStatus();
        vm.expectRevert(VaultState.NotAllowed.selector);
        LongVaultExit(address(longCode)).exitStep(0, 0);
        vm.expectRevert(VaultState.NotAllowed.selector);
        ShortVaultExit(address(shortCode)).report();
    }

    /// Only the exit's selectors reach the module; anything else is refused by the leg.
    function test_fallback_dispatchesTheExitSelectorsOnly() public {
        address spoke = _create(_config());
        (bool ok, bytes memory ret) = spoke.call(abi.encodeWithSignature("selfdestruct()"));
        assertFalse(ok);
        assertEq(bytes4(ret), VaultState.Unsupported.selector);
        // a module function the Hyperliquid leg does not dispatch: the long module's
        (ok, ret) = spoke.call(abi.encodeCall(LongVaultExit.exitStep, (0, 0)));
        assertFalse(ok);
        assertEq(bytes4(ret), VaultState.Unsupported.selector);
        // a dispatched one, through the leg, in its storage
        (uint8 state,,,) = ShortVaultExit(spoke).exitStatus();
        assertEq(state, 0);
    }

    /// The AAVE leg's parts are its own calls only, and its exit waits for the exit state.
    function test_longModule_throughTheLeg() public {
        transmitter.setLocalDomain(ARB_DOMAIN);
        StrategyConfig memory c = _config();
        uint256 deadline = block.timestamp + 1 days;
        address hub = factory.create(STRATEGY, address(owner), c, deadline, _createSig(walletPk, STRATEGY, c, deadline))[1];
        vm.prank(stranger);
        vm.expectRevert(VaultState.NotAllowed.selector);
        LongVaultExit(hub).exitPart(1, 0);
        vm.expectRevert(VaultState.NotExiting.selector);
        LongVaultExit(hub).exitStep(0, 0);
        (bool ok, bytes memory ret) = hub.call(abi.encodeCall(ShortVaultExit.bridgeOut, ()));
        assertFalse(ok);
        assertEq(bytes4(ret), VaultState.Unsupported.selector);
    }

    /// One lock across the leg and its module: a call back into either, during the module's exit step
    /// (Circle pulling the leg's burn), is refused.
    function _reenter(bytes memory callBack) internal returns (bytes memory got) {
        address spoke = _create(_config());
        _deliverReady(spoke, ARB_DOMAIN, VaultBase(spoke).links(0));
        uint256 deadline = block.timestamp + 1 hours;
        VaultBase(spoke).beginExit(deadline, _beginExitSig(STRATEGY, deadline));
        vm.etch(USDC, type(ReentrantUSDC).runtimeCode);
        ReentrantUSDC token = ReentrantUSDC(USDC);
        token.mint(spoke, 50e6);
        token.arm(spoke, callBack);
        core.setExists(spoke, true);
        vm.prank(stranger);
        ShortVaultExit(spoke).bridgeOut();
        assertTrue(token.tried(), "Circle pulled the burn");
        assertEq(messenger.burnCount(), 1, "the exit's own burn went");
        return token.reverted();
    }

    function test_reentrancy_intoTheModule_refused() public {
        bytes memory got = _reenter(abi.encodeCall(ShortVaultExit.bridgeOut, ()));
        assertEq(bytes4(got), VaultState.Reentrancy.selector);
    }

    function test_reentrancy_intoTheLeg_refused() public {
        bytes memory got = _reenter(abi.encodeCall(VaultBase.notifyLink, (0)));
        assertEq(bytes4(got), VaultState.Reentrancy.selector);
    }
}
