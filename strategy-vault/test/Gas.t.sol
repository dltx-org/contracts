// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {Fixture} from "./utils/Fixture.sol";
import {ShortVault} from "../src/ShortVault.sol";
import {ShortVaultExit} from "../src/ShortVaultExit.sol";
import {ShortVaultState} from "../src/ShortVaultState.sol";
import {LogOnlyCoreWriter} from "./mocks/Mocks.sol";

/// Gas of the heaviest exit call: 16 watched DEXes each sending its collateral back, two DEX 0 perps
/// read, every pinned token sold, a transfer, a bridge. HyperEVM's small blocks hold 3M gas (§6). The
/// stubs here cost more than HyperEVM's native precompiles (each read is two calls), so this is an
/// upper bound on the reads.
contract GasTest is Fixture {
    function test_gas_heaviestExitStep() public {
        _world();
        uint256 deadline = block.timestamp + 1 days;
        ShortVault leg = ShortVault(payable(_create(_config())));
        ShortVaultExit vault = ShortVaultExit(address(leg)); // the exit runs through the module
        address v = address(leg);
        core.setExists(v, true);
        leg.beginExit(deadline, _beginExitSig(STRATEGY, deadline));
        ShortVaultState.ExitArgs memory a;
        a.dexes = new ShortVaultState.DexHint[](16);
        for (uint32 d = 1; d <= 16; ++d) {
            core.setMargin(d, v, 5_000_000, 0, 0);
            a.dexes[d - 1] = ShortVaultState.DexHint(d, 0);
        }
        a.cancels = new ShortVaultState.Cancel[](2);
        a.perps = new uint32[](2);
        a.perps[0] = 0;
        a.perps[1] = 5;
        core.setWithdrawable(v, 1_000_000);
        core.setSpot(v, 0, 5_000_000_000);
        core.setSpot(v, HYPE, 50_000_000);
        core.setSpot(v, 235, 2_000_000_000);
        core.setSpot(v, 268, 2_000_000_000);
        core.setSpot(v, 360, 2_000_000_000);
        usdc.mint(v, 1e6);
        vm.etch(CORE_WRITER, type(LogOnlyCoreWriter).runtimeCode); // the real one only logs
        uint256 g = gasleft();
        vault.exitStep(a);
        g -= gasleft();
        emit log_named_uint("exitStep, 16 DEXes, every row", g);
        (, uint32[] memory dexes,,) = vault.exitStatus();
        assertEq(dexes.length, 16);
        assertLt(g, 3_000_000, "fits a HyperEVM small block");
        g = gasleft();
        vault.exitStatus();
        g -= gasleft();
        emit log_named_uint("exitStatus, 16 DEXes", g);
    }

    /// Creating a strategy's members on each chain (the clones, their initialisation, each READY to the
    /// members elsewhere).
    function test_gas_createEachChain() public {
        _world();
        uint256 g = gasleft();
        _create(_config());
        emit log_named_uint("create: the Hyperliquid leg on HyperEVM", g - gasleft());
        transmitter.setLocalDomain(ARB_DOMAIN);
        g = gasleft();
        _create(_config());
        emit log_named_uint("create: the hub and the AAVE leg on Arbitrum", g - gasleft());
    }
}
