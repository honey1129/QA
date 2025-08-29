// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract Hello {
    string public message;

    constructor(string memory _msg) {
        message = _msg;
    }
}
