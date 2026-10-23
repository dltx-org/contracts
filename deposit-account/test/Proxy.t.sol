// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {DepositProxy} from "../src/DepositProxy.sol";
import {ProxyInitCode} from "../src/ProxyInitCode.sol";

/// An implementation for the proxy alone: a store, a revert with data, an echo of the sender and value.
contract ProbeImplementation {
    uint256 public stored;

    error Probe(uint256 code);

    function store(uint256 v) external {
        stored = v;
    }

    function fail(uint256 code) external pure {
        revert Probe(code);
    }

    function who() external payable returns (address, uint256, address) {
        return (msg.sender, msg.value, address(this));
    }
}

/// A maker that answers what it is told, and creates the proxy with CREATE2.
contract ProbeMaker {
    address public proxyImplementation;

    function make(address impl, bytes32 salt) external returns (address made) {
        proxyImplementation = impl;
        bytes memory code = ProxyInitCode.INIT_CODE;
        assembly ("memory-safe") {
            made := create2(0, add(code, 0x20), mload(code), salt)
        }
        delete proxyImplementation;
    }
}

/// owner-upgrades-design.md §A1, §3.1: the one proxy of both families.
contract ProxyTest is Test {
    bytes32 constant SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    event Upgraded(address indexed implementation);

    ProbeMaker maker;
    ProbeImplementation impl;

    function setUp() public {
        maker = new ProbeMaker();
        impl = new ProbeImplementation();
    }

    /// The pinned bytes are this project's build of `DepositProxy`, and HASH their keccak: the hash
    /// the vault project and the engine pin (`DEPOSIT_PROXY_INIT_CODE_HASH`).
    function test_proxy_theInitCodeIsPinned() public pure {
        assertEq(keccak256(type(DepositProxy).creationCode), keccak256(ProxyInitCode.INIT_CODE));
        assertEq(keccak256(ProxyInitCode.INIT_CODE), ProxyInitCode.HASH);
        assertEq(ProxyInitCode.HASH, 0x6f7b25ec6a5059170168f7c23327b6f7e572f9cdcbe26af04cf747b6542bbfc4);
        assertEq(type(DepositProxy).runtimeCode.length, 64);
        assertEq(SLOT, bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1));
    }

    function test_proxy_theConstructorWritesTheMakersImplementation() public {
        address predicted = vm.computeCreate2Address(bytes32(uint256(1)), ProxyInitCode.HASH, address(maker));
        vm.expectEmit(true, false, false, false, predicted);
        emit Upgraded(address(impl));
        address p = maker.make(address(impl), bytes32(uint256(1)));
        assertEq(p, predicted);
        assertEq(address(uint160(uint256(vm.load(p, SLOT)))), address(impl));
    }

    /// The address depends on the maker and the salt only, never on the implementation.
    function test_proxy_theAddressIgnoresTheImplementation() public {
        ProbeImplementation other = new ProbeImplementation();
        uint256 snap = vm.snapshotState();
        address a = maker.make(address(impl), bytes32(uint256(7)));
        vm.revertToState(snap);
        address b = maker.make(address(other), bytes32(uint256(7)));
        assertEq(a, b);
    }

    /// A maker answering zero (outside a creation) or an address without code: no instance.
    function test_proxy_refusesAnImplementationWithoutCode() public {
        assertEq(maker.make(address(0), bytes32(uint256(2))), address(0));
        assertEq(maker.make(address(0xBEEF), bytes32(uint256(3))), address(0));
        // a maker with no `proxyImplementation` at all
        bytes memory code = ProxyInitCode.INIT_CODE;
        address made;
        assembly ("memory-safe") {
            made := create(0, add(code, 0x20), mload(code))
        }
        assertEq(made, address(0));
    }

    function test_proxy_delegatesEveryCall() public {
        address p = maker.make(address(impl), bytes32(uint256(4)));
        ProbeImplementation(p).store(42);
        assertEq(ProbeImplementation(p).stored(), 42);
        assertEq(impl.stored(), 0); // the proxy's storage, not the implementation's
        vm.deal(address(this), 1 ether);
        (address sender, uint256 value, address self) = ProbeImplementation(p).who{value: 5}();
        assertEq(sender, address(this));
        assertEq(value, 5);
        assertEq(self, p);
        vm.expectRevert(abi.encodeWithSelector(ProbeImplementation.Probe.selector, 9));
        ProbeImplementation(p).fail(9);
    }

    /// A plain transfer reaches the implementation, which (like version 1) has no payable entry.
    function test_proxy_aPlainTransferRevertsWithoutAPayableImplementation() public {
        address p = maker.make(address(impl), bytes32(uint256(5)));
        vm.deal(address(this), 1 ether);
        (bool ok,) = p.call{value: 1}("");
        assertFalse(ok);
    }
}
