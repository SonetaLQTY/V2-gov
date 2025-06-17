// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ISTAStaking {
    function deposit(uint256 _amount) external;

    function withdraw(uint256 _amount) external;

    function claim() external;

    function getRewards(address _user) external view returns (uint256 rewards_);
}
