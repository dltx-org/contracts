// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {walletCred} from "./mocks/Mocks.sol";

import {Fixture} from "./utils/Fixture.sol";
import {ShortVault} from "../src/ShortVault.sol";
import {VaultBase, VaultState} from "../src/VaultBase.sol";
import {OwnerMessages, StrategyConfig} from "../src/lib/VaultTypes.sol";

/// The combined security review of 2026-10-18, the mesh's findings: each test PASSES while its gap stands
/// (it asserts the bad outcome); a fix flips it.
contract CombinedReviewMeshTest is Fixture {
    ShortVault hl;
    address thief;
    uint256 thiefPk;
    address thiefAgent = makeAddr("thief-agent");

    function setUp() public {
        _world();
        hl = ShortVault(payable(_create(_config())));
        core.setExists(address(hl), true);
        (thief, thiefPk) = makeAddrAndKey("stolen-credential");
        owner.setWallet(thief, true); // a second credential in effect on this chain's copy, stolen
    }

    function _sig(uint256 pk, uint8 action, address agent, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        return _sign(
            pk,
            address(owner),
            keccak256(abi.encode(OwnerMessages.VAULT_ACTION_TYPEHASH, address(hl), block.chainid, action, agent, nonce, deadline))
        );
    }

    /// CR-E1, fixed: one owner nonce per credential. The thief spends its own nonces, never the owner's:
    /// the owner's cancel at the nonce it read lands; a second credential can't consume it; the burner and
    /// the exit drop a pending owner agent.
    function test_CR_E1_eachCredentialItsOwnNonce() public {
        uint256 deadline = block.timestamp + 3 days;
        bytes32 t = walletCred(thief);
        bytes32 me = walletCred(wallet);
        hl.ownerAction(OwnerMessages.REPLACE_AGENT, thiefAgent, t, deadline, _sig(thiefPk, OwnerMessages.REPLACE_AGENT, thiefAgent, 0, deadline));
        uint256 n = hl.ownerNonceOf(me);
        bytes memory cancel = _sig(walletPk, OwnerMessages.CANCEL_AGENT, address(0), n, deadline);
        // the thief lands no-ops first: they spend the thief's nonce, not the owner's
        hl.ownerAction(OwnerMessages.ALLOW_EXECUTION, address(0), t, deadline, _sig(thiefPk, OwnerMessages.ALLOW_EXECUTION, address(0), 1, deadline));
        hl.ownerAction(OwnerMessages.ALLOW_EXECUTION, address(0), t, deadline, _sig(thiefPk, OwnerMessages.ALLOW_EXECUTION, address(0), 2, deadline));
        // a signature submitted under another credential's name is refused
        vm.expectRevert(VaultState.BadSignature.selector);
        hl.ownerAction(OwnerMessages.CANCEL_AGENT, address(0), t, deadline, cancel);
        hl.ownerAction(OwnerMessages.CANCEL_AGENT, address(0), me, deadline, cancel);
        assertEq(hl.ownerAgent(), address(0), "cancelled");
        // a replay is refused (the owner's nonce is spent)
        vm.expectRevert(VaultState.BadSignature.selector);
        hl.ownerAction(OwnerMessages.CANCEL_AGENT, address(0), me, deadline, cancel);
        // a new proposal: entering the exit drops it
        hl.ownerAction(OwnerMessages.REPLACE_AGENT, thiefAgent, t, deadline, _sig(thiefPk, OwnerMessages.REPLACE_AGENT, thiefAgent, 3, deadline));
        hl.beginExit(deadline, _beginExitSig(STRATEGY, deadline));
        assertEq(hl.ownerAgent(), address(0), "the exit drops a pending owner choice");
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        vm.expectRevert();
        hl.applyOwnerAgent();
        assertEq(hl.agent(), hl.burner());
    }

    /// CR-E3, fixed: `create` refuses a group with no key on this chain (stopped from the start).
    function test_CR_E3_createRefusesAStoppedGroup() public {
        StrategyConfig memory c = _config();
        c.group = 1;
        assertTrue(registry.stopped(1));
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _createSig(walletPk, STRATEGY, c, deadline);
        vm.expectRevert();
        factory.create(STRATEGY, address(owner), c, deadline, sig);
    }

    /// CR-E2 / CR-F1: recovery alone keeps a group's hatch shut by naming a key it holds.
    function test_CR_E2_recoveryAloneHoldsTheHatchShut() public {
        address own = makeAddr("a key recovery names");
        for (uint256 i; i < 4; ++i) {
            vm.warp(vm.getBlockTimestamp() + 6 days);
            vm.prank(recovery);
            registry.setExecutionKey(0, own);
            vm.prank(own);
            registry.checkIn(0);
        }
        assertFalse(registry.stopped(0), "24 days without DLTX's key, the hatch shut");
        vm.prank(stranger);
        vm.expectRevert(VaultState.GroupNotStopped.selector);
        VaultBase(address(hl)).beginExitStopped();
    }
}
