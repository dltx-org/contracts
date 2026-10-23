// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {AssetProfile} from "./Types.sol";

/// What a version-1 member, its modules and the combination factory ask their chain's registry.
interface IRegistryV1 {
    function GROUPS() external view returns (uint8);
    function executionKey(uint8 group) external view returns (address);
    function stopped(uint8 group, uint256 version) external view returns (bool);
    function versionOf(bytes32 manifest) external view returns (uint256);
    function manifestOf(uint256 version) external view returns (bytes32);
    function implementation(uint256 version, uint8 memberType) external view returns (address);
    function profileOpen(bytes32 id) external view returns (bool);
    function profileOf(bytes32 id) external view returns (AssetProfile memory);
    function feeAddress() external view returns (address);
    function recovery() external view returns (address);
}

/// What the registry asks an implementation at a listing (§A3, §A9) and at a profile's acceptance (AP-3).
interface IImplementation {
    function CODE_VERSION() external view returns (uint32);
    function MEMBER_TYPE() external view returns (uint8);
    function listingRegistry() external view returns (address);
    /// Reverts unless this member type's part of `p` holds on this chain (AP-3).
    function checkProfile(AssetProfile calldata p) external view;
}

/// The deposit account's view of a credential's pending removal (owner-upgrades-design.md §A4, §C4):
/// true while a removal of that credential is proposed and not settled; always false on a copy.
interface IOwnerRemovals {
    function removalPendingOf(bytes32 credentialId) external view returns (bool);
}

/// What the shared proxy's constructor asks its maker (owner-upgrades-design.md §A1).
interface IProxyMaker {
    function proxyImplementation() external view returns (address);
}
