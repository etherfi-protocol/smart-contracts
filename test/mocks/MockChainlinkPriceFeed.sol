// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

contract MockChainlinkPriceFeed {
    int256 public answer;
    uint256 public updatedAt;

    constructor(int256 _answer, uint256 _updatedAt) {
        answer = _answer;
        updatedAt = _updatedAt;
    }

    function set(int256 _answer, uint256 _updatedAt) external {
        answer = _answer;
        updatedAt = _updatedAt;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 _answer, uint256 startedAt, uint256 _updatedAt, uint80 answeredInRound)
    {
        return (0, answer, 0, updatedAt, 0);
    }
}
