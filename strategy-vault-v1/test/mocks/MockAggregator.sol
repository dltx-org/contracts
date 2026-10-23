// SPDX-License-Identifier: LicenseRef-DLTX-Source-1.0
pragma solidity 0.8.37;

/// A Chainlink aggregator proxy for the price tests (amendment 2b §3.8): round ids carry their phase in the
/// top 16 bits (`phase << 64 | aggregatorRound`), as the real proxy's do; a round never written either
/// reverts (OCR aggregators: "No data present") or answers zeros (older ones), as `revertOnMissing` says.
contract MockAggregator {
    struct Round {
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
        bool set;
    }

    uint8 public decimals;
    uint80 public latest;
    bool public revertOnMissing = true;
    bool public broken; // every read reverts
    mapping(uint80 => Round) public rounds;
    string public description;

    function setDescription(string calldata d) external {
        description = d;
    }

    constructor(uint8 d) {
        decimals = d;
    }

    function id(uint16 phase, uint64 round) public pure returns (uint80) {
        return (uint80(phase) << 64) | round;
    }

    /// Writes a round and makes it the latest.
    function push(uint80 roundId, int256 answer, uint256 updatedAt) external {
        rounds[roundId] = Round(answer, updatedAt, updatedAt, true);
        latest = roundId;
    }

    /// The sequencer feed's shape: `answer` 0 up, 1 down; `startedAt` the last status change.
    function setStatus(uint80 roundId, int256 answer, uint256 startedAt) external {
        rounds[roundId] = Round(answer, startedAt, block.timestamp, true);
        latest = roundId;
    }

    function setRevertOnMissing(bool r) external {
        revertOnMissing = r;
    }

    function setBroken(bool b) external {
        broken = b;
    }

    function getRoundData(uint80 roundId) public view returns (uint80, int256, uint256, uint256, uint80) {
        require(!broken, "broken");
        Round memory r = rounds[roundId];
        if (!r.set) {
            require(!revertOnMissing, "No data present");
            return (roundId, 0, 0, 0, 0);
        }
        return (roundId, r.answer, r.startedAt, r.updatedAt, roundId);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return getRoundData(latest);
    }
}

/// A feed answering garbage: too little return data.
contract ShortAnswerFeed {
    fallback() external {
        assembly {
            mstore(0, 1)
            return(0, 32)
        }
    }
}
