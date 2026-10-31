// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {FixtureV1} from "./FixtureV1.sol";
import {MemberState} from "../src/MemberState.sol";
import {AaveV3AssetLegState} from "../src/AaveV3AssetLegState.sol";
import {HyperCoreLegState} from "../src/HyperCoreLegState.sol";
import {HyperCoreLeg} from "../src/HyperCoreLeg.sol";
import {MockERC20} from "./mocks/Mocks.sol";

/// The external audit of 2026-10-26, finding 8: `test.mjs` compares the layouts to their pinned files, but
/// `forge test` alone did not see a moved slot (its own checks compare two builds of the same source). Here
/// witness fields of initialised instances are read by `vm.load` at the slots `layouts/*.txt` pins: a field
/// inserted before them fails this suite on its own. The slots are constants on purpose; a version that
/// appends keeps them.
contract LayoutWitnessV1Test is FixtureV1 {
    // MemberState's prefix (every member): layouts/Hub.txt, AaveV3AssetLeg.txt, HyperCoreLeg.txt
    uint256 constant OWNER_SLOT = 1;
    uint256 constant LOCKED_SLOT = 12;
    uint256 constant CODE_VERSION_SLOT = 27; // offset 17, uint32
    uint256 constant PENDING_SLOT = 29; // PendingAction.kind at offset 0
    uint256 constant OTHERS_PENDING_SLOT = 32;
    // the AAVE leg's own
    uint256 constant HEALTH_FLOOR_SLOT = 73; // offset 0, uint64
    uint256 constant SWAPPING_SLOT = 75;
    // the Hyperliquid leg's own
    uint256 constant EXIT_AGENT_SLOT = 79;
    uint256 constant BURNING_SLOT = 90; // offset 0, bool; burnerNonce at offset 1
    // the contract route's, appended (hyperliquid-contract-route-design.md §4.1): route at slot 90 offset 9,
    // side 10, maxLeverageX100 11; the builder at 92; referralSetup at 95 (spec §16), with setupOpen at
    // offset 10, setupConfirmed 11 and setupIn (uint64) 12, the slot's last fields
    uint256 constant ROUTE_SLOT = 90;
    uint256 constant BUILDER_SLOT = 92;
    uint256 constant REFERRAL_SETUP_SLOT = 95;

    function _word(address a, uint256 slot) internal view returns (uint256) {
        return uint256(vm.load(a, bytes32(slot)));
    }

    function test_witness_theHubAndTheLong() public {
        _arbitrum();
        address[] memory made = _create(_btcSpec());
        (address hub, address long) = (made[0], made[1]);
        for (uint256 i; i < 2; ++i) {
            address m = made[i];
            assertEq(address(uint160(_word(m, OWNER_SLOT))), MemberState(m).owner(), "owner");
            assertEq(_word(m, LOCKED_SLOT), 0, "the lock, released");
            assertEq(uint32(_word(m, CODE_VERSION_SLOT) >> (17 * 8)), MemberState(m).codeVersion(), "codeVersion");
            assertEq(uint8(_word(m, PENDING_SLOT)), 0, "no pending action");
            assertEq(_word(m, OTHERS_PENDING_SLOT), MemberState(m).othersPending(), "othersPending");
        }
        assertEq(uint32(_word(hub, CODE_VERSION_SLOT) >> (17 * 8)), 1);
        assertEq(uint64(_word(long, HEALTH_FLOOR_SLOT)), AaveV3AssetLegState(long).healthFloor(), "healthFloor");
        assertGt(AaveV3AssetLegState(long).healthFloor(), 0);
        assertEq(_word(long, SWAPPING_SLOT), 0, "_swapping");
    }

    function test_witness_theShort() public {
        _hyperEvm();
        address short = _create(_btcSpec())[0];
        assertEq(uint32(_word(short, CODE_VERSION_SLOT) >> (17 * 8)), 1);
        assertEq(address(uint160(_word(short, OWNER_SLOT))), MemberState(short).owner());
        vm.store(short, bytes32(EXIT_AGENT_SLOT), bytes32(uint256(0xA6E17)));
        assertEq(HyperCoreLegState(short).exitAgent(), address(0xA6E17), "exitAgent");
        uint256 w = _word(short, ROUTE_SLOT);
        assertEq(uint8(w >> (9 * 8)), HyperCoreLegState(short).route(), "route");
        assertEq(uint8(w >> (10 * 8)), HyperCoreLegState(short).side(), "side");
        assertEq(uint16(w >> (11 * 8)), HyperCoreLegState(short).maxLeverageX100(), "maxLeverageX100");
        assertEq(HyperCoreLegState(short).maxLeverageX100(), 1000);
        vm.store(short, bytes32(BURNING_SLOT), bytes32(uint256(1)));
        assertTrue(HyperCoreLegState(short).burning(), "burning");
        vm.store(short, bytes32(BUILDER_SLOT), bytes32(uint256(0xB1)));
        assertEq(HyperCoreLegState(short).builder(), address(0xB1), "builder");
        vm.store(short, bytes32(REFERRAL_SETUP_SLOT), bytes32(uint256(1)));
        assertTrue(HyperCoreLegState(short).referralSetup(), "referralSetup");
        vm.store(short, bytes32(REFERRAL_SETUP_SLOT), bytes32(uint256(1) << (10 * 8)));
        assertTrue(HyperCoreLegState(short).setupOpen(), "setupOpen");
        assertFalse(HyperCoreLegState(short).referralSetup());
        vm.store(short, bytes32(REFERRAL_SETUP_SLOT), bytes32(uint256(1) << (11 * 8)));
        assertTrue(HyperCoreLegState(short).setupConfirmed(), "setupConfirmed");
        assertFalse(HyperCoreLegState(short).setupOpen());
    }

    /// `setupIn` (internal, no getter): written by the leg's own `toMargin` on a fresh account, read here at
    /// slot 95 offset 12.
    function test_witness_theShortsSetupIn() public {
        _hyperEvm();
        address short = _create(_btcSpec())[0];
        MockERC20(HYPER_USDC).mint(short, 3e6);
        vm.prank(key);
        HyperCoreLeg(payable(short)).toMargin(3e6);
        assertEq(uint64(_word(short, REFERRAL_SETUP_SLOT) >> (12 * 8)), 3e6, "setupIn");
        assertEq(_word(short, REFERRAL_SETUP_SLOT) & ((uint256(1) << (12 * 8)) - 1), 0, "nothing else in slot 95");
    }
}
