// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

function _lpTokenToVotes(uint256 _lpTokenAmount, uint256 _timestamp, uint256 _offset) pure returns (uint256) {
    uint256 prod = _lpTokenAmount * _timestamp;
    return prod > _offset ? prod - _offset : 0;
}
