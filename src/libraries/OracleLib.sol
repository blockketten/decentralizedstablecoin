// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

/**
 * @title OracleLib
 * @dev Library for Oracle contract
 * @notice This library is used to check the Chainlink Oracle for stale data
 * @notice If a price is stale, the function will revert, and render the DSCEngine contract unusable - this is by design, as a safety measure
 */

import {AggregatorV3Interface} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

library OracleLib {
    error OracleLib__StalePrice();
    uint256 private constant TIMEOUT = 3 hours; // 3 * 60 * 60 = 10800 seconds

    function staleCheckLatestRoundData(
        AggregatorV3Interface priceFeed
    ) public view returns (uint80, int256, uint256, uint256, uint80) {
        (
            uint80 roundID,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();

        uint256 secondsSince = block.timestamp - updatedAt;

        if (secondsSince > TIMEOUT) revert OracleLib__StalePrice();
        return (roundID, answer, startedAt, updatedAt, answeredInRound);
    }
}
