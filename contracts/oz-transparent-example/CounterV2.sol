// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./CounterV1.sol";

contract CounterV2 is CounterV1 {

    uint256 public bonus;


    function migrate(uint256 bonus_) external reinitializer(2) {
        bonus = bonus_;
    }


    function countWithBonus() external view returns (uint256) {
        return count + bonus;
    }

    uint256[48] private __gapV2;
}
