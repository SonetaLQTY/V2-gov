// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin/contracts/interfaces/IERC20.sol";

import {IPairSonataStaking} from "../interfaces/IPairSonataStaking.sol";

import {PermitParams} from "../utils/Types.sol";

interface IUserProxy {
    /// @notice Address of the PairSonata token
    /// @return pairSonata Address of the PairSonata token
    function pairSonata() external view returns (IERC20 pairSonata);
    /// @notice Address of the LUSD token
    /// @return lusd Address of the LUSD token
    function lusd() external view returns (IERC20 lusd);
    /// @notice Address of the V1 PairSonata staking contract
    /// @return stakingV1 Address of the V1 PairSonata staking contract
    function stakingV1() external view returns (IPairSonataStaking stakingV1);
    /// @notice Address of the V2 PairSonata staking contract
    /// @return stakingV2 Address of the V2 PairSonata staking contract
    function stakingV2() external view returns (address stakingV2);

    /// @notice Stakes a given amount of PairSonata tokens in the V1 staking contract
    /// @dev The PairSonata tokens must be approved for transfer by the user
    /// @param _amount Amount of PairSonata tokens to stake
    /// @param _pairSonataFrom Address from which to transfer the PairSonata tokens
    /// @param _doSendRewards If true, send rewards claimed from PairSonata staking
    /// @param _recipient Address to which the tokens should be sent
    /// @return lusdReceived Amount of LUSD tokens received as a side-effect of staking new PairSonata
    /// @return lusdSent Amount of LUSD tokens sent to `_recipient` (may include previously received LUSD)
    /// @return ethReceived Amount of ETH received as a side-effect of staking new PairSonata
    /// @return ethSent Amount of ETH sent to `_recipient` (may include previously received ETH)
    function stake(uint256 _amount, address _pairSonataFrom, bool _doSendRewards, address _recipient)
        external
        returns (uint256 lusdReceived, uint256 lusdSent, uint256 ethReceived, uint256 ethSent);

    /// @notice Stakes a given amount of PairSonata tokens in the V1 staking contract using a permit
    /// @param _amount Amount of PairSonata tokens to stake
    /// @param _pairSonataFrom Address from which to transfer the PairSonata tokens
    /// @param _permitParams Parameters for the permit data
    /// @param _doSendRewards If true, send rewards claimed from PairSonata staking
    /// @param _recipient Address to which the tokens should be sent
    /// @return lusdReceived Amount of LUSD tokens received as a side-effect of staking new PairSonata
    /// @return lusdSent Amount of LUSD tokens sent to `_recipient` (may include previously received LUSD)
    /// @return ethReceived Amount of ETH received as a side-effect of staking new PairSonata
    /// @return ethSent Amount of ETH sent to `_recipient` (may include previously received ETH)
    function stakeViaPermit(
        uint256 _amount,
        address _pairSonataFrom,
        PermitParams calldata _permitParams,
        bool _doSendRewards,
        address _recipient
    ) external returns (uint256 lusdReceived, uint256 lusdSent, uint256 ethReceived, uint256 ethSent);

    /// @notice Unstakes a given amount of PairSonata tokens from the V1 staking contract and claims the accrued rewards
    /// @param _amount Amount of PairSonata tokens to unstake
    /// @param _doSendRewards If true, send rewards claimed from PairSonata staking
    /// @param _recipient Address to which the tokens should be sent
    /// @return pairSonataReceived Amount of PairSonata tokens actually unstaked (may be lower than `_amount`)
    /// @return pairSonataSent Amount of PairSonata tokens sent to `_recipient` (may include PairSonata sent to the proxy from sources other than V1 staking)
    /// @return lusdReceived Amount of LUSD tokens received as a side-effect of staking new PairSonata
    /// @return lusdSent Amount of LUSD tokens claimed (may include previously received LUSD)
    /// @return ethReceived Amount of ETH received as a side-effect of staking new PairSonata
    /// @return ethSent Amount of ETH claimed (may include previously received ETH)
    function unstake(uint256 _amount, bool _doSendRewards, address _recipient)
        external
        returns (
            uint256 pairSonataReceived,
            uint256 pairSonataSent,
            uint256 lusdReceived,
            uint256 lusdSent,
            uint256 ethReceived,
            uint256 ethSent
        );

    /// @notice Returns the current amount PairSonata staked by a user in the V1 staking contract
    /// @return staked Amount of PairSonata tokens staked
    function staked() external view returns (uint256);
}
