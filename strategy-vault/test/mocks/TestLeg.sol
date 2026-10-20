// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {VaultBase, VaultState} from "../../src/VaultBase.sol";
import {Assets, Holding, Legs} from "../../src/lib/VaultTypes.sol";

/*
 * A TEST-ONLY leg type (amendment 2a §9): the shared base and nothing of a venue, so the tests can play
 * what 2a builds no factory for — up to four legs around a hub, some on this chain and some elsewhere. It
 * holds the HyperEVM USDC the fixture etches; it reports that USDC as `USD`. Its exit sends everything to
 * the hub. Its module carries `exitStep`, `receiveMint` and `report`, as the real legs' do. Nothing here
 * is deployed.
 */
abstract contract TestLegState is VaultState {
    address internal constant TOKEN = 0xb88339CB7199b77E23DB6E890353E22632Ba630f;
    /// Amendment 2b's tests: an ETH position the test sets, by the leg's own counted call (`trade`) or by
    /// a third party unseen (`liquidate`); a block of last move for the report.
    int256 public eth;
    int256 public usd; // USDC units: a signed position beside the USDC held (a debt below zero)
    uint64 public lastMove;
    /// Amendment 2d §5.2: what this leg states it owes in exit (`exitDebt()`), as the test sets it.
    uint256 public owed;

    function _usdc() internal pure override returns (address) {
        return TOKEN;
    }

    function _tracked() internal pure override returns (bool) {
        return true;
    }

    function _holdings() internal view override returns (Holding[] memory h, uint256 extra) {
        h = new Holding[](eth == 0 ? 1 : 2);
        (bool ok, bytes memory out) = TOKEN.staticcall(abi.encodeWithSignature("balanceOf(address)", address(this)));
        h[0] = Holding(Assets.USD, ((ok ? int256(abi.decode(out, (uint256))) : int256(0)) + usd) * 1e12);
        if (eth != 0) h[1] = Holding(Assets.ETH, eth);
        extra = lastMove;
    }
}

contract TestLegExit is TestLegState {
    function exitDebt() external view delegated returns (uint256) {
        return exiting ? owed : 0;
    }

    function exitStep() external delegated nonReentrant inExit {
        _sendAllToHub();
    }

    function receiveMint(bytes calldata message, bytes calldata attestation) external delegated nonReentrant {
        _receiveMint(message, attestation);
    }

    function report() external delegated nonReentrant {
        _report();
    }

    function holdings()
        external
        view
        delegated
        returns (Holding[] memory, uint256[4] memory, uint256[4] memory, uint64, uint64, uint64, bool)
    {
        return _legView();
    }
}

contract TestLeg is VaultBase, TestLegState {
    constructor(address exitModule_, bytes32 hash_) VaultBase(exitModule_, hash_) {}

    function legInfo() external pure returns (bytes32 legType, uint8 roles, uint8 valueKind) {
        return (keccak256("dltx.leg.test"), Legs.ROLE_LONG | Legs.ROLE_SHORT, Legs.VALUE_READ);
    }

    function paramsType() external pure returns (string memory) {
        return "TestLeg(uint256 seven)";
    }

    /// Accepts exactly one word, 7.
    function validateParams(bytes calldata params) external pure {
        if (params.length != 32 || abi.decode(params, (uint256)) != 7) revert Unsupported();
    }

    function _initParams(bytes calldata) internal override {}

    function _onExit() internal override {}

    function _exitSelector(bytes4 s) internal pure override returns (bool) {
        return s == TestLegExit.exitStep.selector || s == TestLegExit.receiveMint.selector
            || s == TestLegExit.report.selector || s == TestLegExit.holdings.selector
            || s == TestLegExit.exitDebt.selector;
    }

    /// A market call of the leg's own: counted.
    function trade(int256 ethDelta, int256 usdDelta) external counted {
        eth += ethDelta;
        usd += usdDelta;
    }

    /// A third party moving the position (a liquidation): no call of the leg, not counted.
    function liquidate(int256 ethDelta) external {
        eth += ethDelta;
    }

    function setOwed(uint256 a) external {
        owed = a;
    }

    function setLastMove(uint64 b) external {
        lastMove = b;
    }

    /// The execution key's send to member `k` (VaultBase's `_send`), fast at most 50 bp, its fee charged
    /// to a 100 bp daily budget of its USDC.
    function send(uint8 k, uint256 amount, bool fast, uint256 maxFee) external onlyExecution nonReentrant {
        (bool ok, bytes memory out) = TOKEN.staticcall(abi.encodeWithSignature("balanceOf(address)", address(this)));
        uint256 held = ok ? abi.decode(out, (uint256)) : 0;
        _chargeFee(_send(k, amount, fast, maxFee, 50), held, 100);
    }
}
