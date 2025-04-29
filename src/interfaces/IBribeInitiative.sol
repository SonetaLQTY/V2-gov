// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin/contracts/interfaces/IERC20.sol";

import {IGovernance} from "./IGovernance.sol";

interface IBribeInitiative {
    event DepositBribe(address depositor, uint256 oneAmount, uint256 bribeTokenAmount, uint256 epoch);
    event ModifyPairSonataAllocation(address user, uint256 epoch, uint256 pairSonataAllocated, uint256 offset);
    event ModifyTotalPairSonataAllocation(uint256 epoch, uint256 totalPairSonataAllocated, uint256 offset);
    event ClaimBribe(address user, uint256 epoch, uint256 oneAmount, uint256 bribeTokenAmount);

    /// @notice Address of the governance contract
    /// @return governance Adress of the governance contract
    function governance() external view returns (IGovernance governance);
    /// @notice Address of the ONE token
    /// @return one Address of the ONE token
    function one() external view returns (IERC20 one);
    /// @notice Address of the bribe token
    /// @return bribeToken Address of the bribe token
    function bribeToken() external view returns (IERC20 bribeToken);

    struct Bribe {
        uint256 remainingOneAmount;
        uint256 remainingBribeTokenAmount; // [scaled as 10 ** bribeToken.decimals()]
        uint256 claimedVotes;
    }

    /// @notice Amount of bribe tokens deposited for a given epoch
    /// @param _epoch Epoch at which the bribe was deposited
    /// @return remainingOneAmount Amount of ONE tokens that haven't been claimed yet
    /// @return remainingBribeTokenAmount Amount of bribe tokens that haven't been claimed yet
    /// @return claimedVotes Sum of voting power of users who have already claimed their bribes
    function bribeByEpoch(uint256 _epoch)
        external
        view
        returns (uint256 remainingOneAmount, uint256 remainingBribeTokenAmount, uint256 claimedVotes);
    /// @notice Check if a user has claimed bribes for a given epoch
    /// @param _user Address of the user
    /// @param _epoch Epoch at which the bribe may have been claimed by the user
    /// @return claimed If the user has claimed the bribe
    function claimedBribeAtEpoch(address _user, uint256 _epoch) external view returns (bool claimed);

    /// @notice Total PairSonata allocated to the initiative at a given epoch
    ///         Voting power can be calculated as `totalPairSonataAllocated * timestamp - offset`
    /// @param _epoch Epoch at which the PairSonata was allocated
    /// @return totalPairSonataAllocated Total PairSonata allocated
    /// @return offset Voting power offset
    function totalPairSonataAllocatedByEpoch(uint256 _epoch)
        external
        view
        returns (uint256 totalPairSonataAllocated, uint256 offset);
    /// @notice PairSonata allocated by a user to the initiative at a given epoch
    ///         Voting power can be calculated as `pairSonataAllocated * timestamp - offset`
    /// @param _user Address of the user
    /// @param _epoch Epoch at which the PairSonata was allocated by the user
    /// @return pairSonataAllocated PairSonata allocated by the user
    /// @return offset Voting power offset
    function pairSonataAllocatedByUserAtEpoch(address _user, uint256 _epoch)
        external
        view
        returns (uint256 pairSonataAllocated, uint256 offset);

    /// @notice Deposit bribe tokens for a given epoch
    /// @dev The caller has to approve this contract to spend the ONE and bribe tokens.
    /// The caller can only deposit bribes for future epochs
    /// @param _oneAmount Amount of ONE tokens to deposit
    /// @param _bribeTokenAmount Amount of bribe tokens to deposit
    /// @param _epoch Epoch at which the bribe is deposited
    function depositBribe(uint256 _oneAmount, uint256 _bribeTokenAmount, uint256 _epoch) external;

    struct ClaimData {
        // Epoch at which the user wants to claim the bribes
        uint256 epoch;
        // Epoch at which the user updated the PairSonata allocation for this initiative
        uint256 prevPairSonataAllocationEpoch;
        // Epoch at which the total PairSonata allocation is updated for this initiative
        uint256 prevTotalPairSonataAllocationEpoch;
    }

    /// @notice Claim bribes for a user
    /// @dev The user can only claim bribes for past epochs.
    /// The arrays `_epochs`, `_prevPairSonataAllocationEpochs` and `_prevTotalPairSonataAllocationEpochs` should be sorted
    /// from oldest epoch to the newest. The length of the arrays has to be the same.
    /// @param _claimData Array specifying the epochs at which the user wants to claim the bribes
    function claimBribes(ClaimData[] calldata _claimData)
        external
        returns (uint256 oneAmount, uint256 bribeTokenAmount);

    /// @notice Given a user address return the last recorded epoch for their allocation
    function getMostRecentUserEpoch(address _user) external view returns (uint256);

    /// @notice Return the last recorded epoch for the system
    function getMostRecentTotalEpoch() external view returns (uint256);
}
