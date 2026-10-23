// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {PriceSourcePin, SequencerPin} from "./PriceSource.sol";
import {Assets} from "./VaultTypes.sol";

/*
 * Today's combination's fee pins (step 11e2 amendment 2b §3.8): the hub on Arbitrum values ETH at
 * Chainlink's ETH / USD and checks Arbitrum's sequencer uptime feed. One place, read by the deploy script
 * and the tests, so the combination factory's constructor arguments (and so its address) are pinned once.
 *
 * `maxAge` is one hour, the operator's call of 2026-10-16 replacing the spec's 25 hours: Chainlink's
 * reference data gives this feed a 1,755 s heartbeat (0.05 % deviation), not 24 hours.
 */
library FeePins {
    uint32 internal constant ARBITRUM = 3;
    /// Chainlink ETH / USD on Arbitrum One (8 decimals; `description()` "ETH / USD").
    address internal constant ETH_USD = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    uint32 internal constant ETH_USD_MAX_AGE = 1 hours;
    /// Chainlink's L2 Sequencer Uptime Status Feed on Arbitrum One.
    address internal constant SEQUENCER = 0xFdB631F5EE196F0ed6FAa767959853A9F217697D;

    function prices() internal pure returns (PriceSourcePin[] memory p) {
        p = new PriceSourcePin[](1);
        p[0] = PriceSourcePin(ARBITRUM, Assets.ETH, 1, ETH_USD, address(0), ETH_USD_MAX_AGE);
    }

    function sequencers() internal pure returns (SequencerPin[] memory s) {
        s = new SequencerPin[](1);
        s[0] = SequencerPin(ARBITRUM, SEQUENCER);
    }
}
