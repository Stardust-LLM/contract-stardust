// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title TestEthUsdFeed — TESTNET ONLY
 * @notice Robinhood Chain testnet has no Chainlink feeds. This stands in for the ETH/USD proxy (same interface,
 *         8 decimals). The owner sets the price; it never goes stale. Mainnet uses Chainlink
 *         0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9.
 */
contract TestEthUsdFeed is Ownable {
    int256 public answer;
    uint80 public round;

    event AnswerUpdated(int256 answer, uint80 round);

    constructor(address owner_, int256 answer_) Ownable(owner_) {
        _set(answer_);
    }

    function setAnswer(int256 answer_) external onlyOwner {
        _set(answer_);
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external pure returns (string memory) {
        return "ETH / USD (testnet stand-in)";
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (round, answer, block.timestamp, block.timestamp, round);
    }

    function _set(int256 answer_) internal {
        answer = answer_;
        round += 1;
        emit AnswerUpdated(answer_, round);
    }
}
