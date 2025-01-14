pragma solidity ^0.8.18;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title OracleLib
 * @author just_bytes
 * @notice Library for checking the price of the chainlink oracle for stale data. if a price is stale,
 * the function will revert and make the DSLEngine unusable - this is intentional.
 *
 *
 * Known issue:
 *  If chainlink blows up and you have a lot of money in the system, you can't get out.
 *
 */
library OracleLib {
    error OracleLib__StalePrice();

    uint256 private constant TIMEOUT = 3 hours;

    function staleCheckLatestRoundData(AggregatorV3Interface priceFeed)
        public
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            priceFeed.latestRoundData();
        uint256 secondsSinceUpdated = block.timestamp - updatedAt;
        if (secondsSinceUpdated > TIMEOUT) {
            revert OracleLib__StalePrice();
        }
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}
