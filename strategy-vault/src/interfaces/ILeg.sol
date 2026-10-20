// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

/*
 * What a combination factory asks of a member's code (step 11e2 amendment 2a, revision 1, §3.5): its
 * parameters' validation and the clone's one-time initialisation; of a leg's code, also its
 * self-description. The rest of the member standard (the owner's actions, the exit, the links, the
 * money between members) is `VaultBase`'s.
 */
interface IMember {
    /// Reverts unless `params` are this member type's, within its bounds, naming its pinned protocols.
    function validateParams(bytes calldata params) external view;

    /// Amendment 2d §4.2: this member type's parameters as an EIP-712 struct type, `Name(type field,…)`,
    /// the fields `params`' in order, every one static; the combination factory checks it against its pin.
    function paramsType() external pure returns (string memory);

    /// The factory, once, in the transaction that creates the clone. `links` are every other member of
    /// the strategy (a leg's link 0 is its hub; a hub's links are its legs); `domains` their CCTP domains.
    function initialize(
        address owner,
        address registry,
        address[] calldata links,
        uint32[] calldata domains,
        uint8 group,
        bytes32 strategyId,
        bytes32 configHash,
        bytes calldata params
    ) external;
}

interface ILeg is IMember {
    /// The leg type (a fixed tag), the roles it can play (a bit per `Legs.ROLE_*`), and how its value is
    /// known (`Legs.VALUE_*`). Every leg is the same kind of member: no hub mode (revision 1).
    function legInfo() external pure returns (bytes32 legType, uint8 roles, uint8 valueKind);
}
