// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

function _staTokenToVotes(uint256 _staTokenAmount, uint256 _timestamp, uint256 _offset) pure returns (uint256) {
    uint256 prod = _staTokenAmount * _timestamp;
    return prod > _offset ? prod - _offset : 0;
}
