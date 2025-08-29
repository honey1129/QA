// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract CounterV1 is Initializable, OwnableUpgradeable {

    uint256 public count;


    function initialize(address owner_, uint256 initCount) public initializer {
        __Ownable_init(owner_);
        count = initCount;
    }

    function inc() external onlyOwner {
        unchecked { count += 1; }
    }


    uint256[49] private __gap;
}
