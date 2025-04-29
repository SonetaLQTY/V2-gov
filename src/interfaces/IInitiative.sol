// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IGovernance} from "./IGovernance.sol";

interface IInitiative {
    /// @notice Callback hook that is called by Governance after the initiative was successfully registered
    /// @param _atEpoch Epoch at which the initiative is registered
    function onRegisterInitiative(uint256 _atEpoch) external;

    /// @notice Callback hook that is called by Governance after the initiative was unregistered
    /// @param _atEpoch Epoch at which the initiative is unregistered
    function onUnregisterInitiative(uint256 _atEpoch) external;

    /// @notice Callback hook that is called by Governance after the PairSonata allocation is updated by a user
    /// @param _currentEpoch Epoch at which the PairSonata allocation is updated
    /// @param _user Address of the user that updated their PairSonata allocation
    /// @param _userState User state
    /// @param _allocation Allocation state from user to initiative
    /// @param _initiativeState Initiative state
    function onAfterAllocatePairSonata(
        uint256 _currentEpoch,
        address _user,
        IGovernance.UserState calldata _userState,
        IGovernance.Allocation calldata _allocation,
        IGovernance.InitiativeState calldata _initiativeState
    ) external;

    /// @notice Callback hook that is called by Governance after the claim for the last epoch was distributed
    /// to the initiative
    /// @param _claimEpoch Epoch at which the claim was distributed
    /// @param _one Amount of ONE that was distributed
    function onClaimForInitiative(uint256 _claimEpoch, uint256 _one) external;
}
