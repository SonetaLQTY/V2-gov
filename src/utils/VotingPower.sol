// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

function _pairSonataToVotes(uint256 _pairSonataAmount, uint256 _timestamp, uint256 _offset) pure returns (uint256) {
    uint256 prod = _pairSonataAmount * _timestamp;
    return prod > _offset ? prod - _offset : 0;
}
