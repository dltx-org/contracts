// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

import {Test, console2} from "forge-std/Test.sol";
import {PriceSource, PriceSourcePin} from "../src/lib/PriceSource.sol";
import {PriceSourceHarness} from "./PriceSource.t.sol";

interface IFeed {
    function description() external view returns (string memory);
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function getRoundData(uint80) external view returns (uint80, int256, uint256, uint256, uint80);
}

/// Amendment 2b §3.8 on the Arbitrum fork: today's pins, the real Chainlink ETH / USD proxy and the L2
/// sequencer uptime feed. Runs with `ARBITRUM_RPC_URL`, skips otherwise.
contract PriceSourceForkTest is Test {
    address constant ETH_USD = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address constant SEQUENCER = 0xFdB631F5EE196F0ed6FAa767959853A9F217697D;
    uint256 constant PINNED_BLOCK = 514_790_000; // 2026-10-14, the AAVE leg's fork block
    // The operator's call (2026-10-16), replacing §11.5's 25 hours: Chainlink's reference data gives this
    // feed a 1,755 s heartbeat (0.05 % threshold), not 24 hours, so the pin allows about twice that.
    uint32 constant MAX_AGE = 1 hours;

    bool forked;
    PriceSourceHarness h;
    PriceSourcePin pin;

    function setUp() public {
        string memory url = vm.envOr("ARBITRUM_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url, vm.envOr("ARBITRUM_FORK_BLOCK", PINNED_BLOCK));
        (bool ok,) = address(vm).call(abi.encodeWithSignature("setEvmVersion(string)", "cancun"));
        require(ok, "setEvmVersion");
        forked = true;
        h = new PriceSourceHarness();
        pin = PriceSourcePin(3, "ETH", PriceSource.KIND_FEED, ETH_USD, address(0), MAX_AGE);
    }

    modifier onFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    function _hints(uint80 a) internal pure returns (uint80[] memory x) {
        x = new uint80[](1);
        x[0] = a;
    }

    function test_fork_todaysPins() public onFork {
        assertEq(IFeed(ETH_USD).description(), "ETH / USD");
        assertEq(IFeed(ETH_USD).decimals(), 8);
        (bool up, bytes4 why) = h.sequencerUp(SEQUENCER, vm.getBlockTimestamp());
        assertTrue(up, "the sequencer feed says Arbitrum is up");
        assertEq(why, bytes4(0));
    }

    /// The round in effect at an instant between two real rounds: accepted at the feed's answer × 1e10;
    /// the rounds on either side refused.
    function test_fork_roundInEffect() public onFork {
        (uint80 latest, int256 answer, , uint256 updatedAt,) = IFeed(ETH_USD).latestRoundData();
        (bool ok, uint256 p,) = h.priceAt(pin, vm.getBlockTimestamp(), _hints(latest));
        assertTrue(ok, "the latest round at the block's time");
        assertEq(p, uint256(answer) * 1e10);
        // walk back to a pair of rounds at least 2 s apart
        uint80 prev = latest - 1;
        (, int256 prevAnswer,, uint256 prevAt,) = IFeed(ETH_USD).getRoundData(prev);
        while (updatedAt - prevAt < 2) {
            latest = prev;
            updatedAt = prevAt;
            prev -= 1;
            (, prevAnswer,, prevAt,) = IFeed(ETH_USD).getRoundData(prev);
        }
        uint256 t = prevAt + (updatedAt - prevAt) / 2;
        (ok, p,) = h.priceAt(pin, t, _hints(prev));
        assertTrue(ok, "the round in effect at t");
        assertEq(p, uint256(prevAnswer) * 1e10);
        bytes4 why;
        (ok,, why) = h.priceAt(pin, t, _hints(latest));
        assertFalse(ok, "a round after t");
        assertEq(why, PriceSource.BadRound.selector);
        (ok,, why) = h.priceAt(pin, t, _hints(prev - 1));
        assertFalse(ok, "a round before the one in effect");
        assertEq(why, PriceSource.BadRound.selector);
    }

    /// Too old at t: the latest round priced `maxAge + 1` after its update.
    function test_fork_staleAtMaxAge() public onFork {
        (uint80 latest,,, uint256 updatedAt,) = IFeed(ETH_USD).latestRoundData();
        vm.warp(updatedAt + MAX_AGE + 1);
        (bool ok,, bytes4 why) = h.priceAt(pin, updatedAt + MAX_AGE + 1, _hints(latest));
        assertFalse(ok);
        assertEq(why, PriceSource.StalePrice.selector);
        (ok,,) = h.priceAt(pin, updatedAt + MAX_AGE, _hints(latest));
        assertTrue(ok);
    }

    /// For the build notes: the largest gap between the last 40 rounds before the fork block, beside
    /// Chainlink's published heartbeat.
    function test_fork_measureRoundGaps() public onFork {
        (uint80 id,,, uint256 at,) = IFeed(ETH_USD).latestRoundData();
        uint256 maxGap;
        uint256 first = at;
        for (uint256 i; i < 40; ++i) {
            (,,, uint256 prevAt,) = IFeed(ETH_USD).getRoundData(id - 1);
            if (at - prevAt > maxGap) maxGap = at - prevAt;
            at = prevAt;
            id -= 1;
        }
        console2.log("ETH / USD: largest gap between the last 40 rounds (s)", maxGap);
        console2.log("ETH / USD: span of the last 40 rounds (s)", first - at);
        console2.log("ETH / USD: age of the latest round at the fork block (s)", vm.getBlockTimestamp() - first);
    }
}
