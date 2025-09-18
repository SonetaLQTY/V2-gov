// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ILiquidityBeetsGauge {
    function deposit_reward_token(address _reward_token, uint256 _amount) external;
}
