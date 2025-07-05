// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin/contracts/interfaces/IERC20.sol";

uint256 constant UNREGISTERED_INITIATIVE = type(uint256).max;

interface ISingleStaking {
    function depositAsAuthority(address _user, uint256 _amount) external;
    function withdrawAsAuthority(address _user, uint256 _amount) external;
}

interface IGovernance {
    enum HookStatus {
        Failed,
        Succeeded,
        NotCalled
    }

    /// @notice Emitted when a user deposits STAToken
    /// @param user The account depositing STAToken
    /// @param staTokenAmount The amount of LP tokens being deposited
    event DepositSTAToken(address indexed user, uint256 staTokenAmount);

    /// @notice Emitted when a user withdraws STAToken or claims V1 staking rewards
    /// @param user The account withdrawing STAToken or claiming V1 staking rewards
    /// @param staTokenAmount The amount of LP tokens being withdrawn
    event WithdrawSTAToken(address indexed user, uint256 staTokenAmount);

    event SnapshotVotes(uint256 votes, uint256 forEpoch, uint256 oneAccrued);
    event SnapshotVotesForInitiative(address indexed initiative, uint256 votes, uint256 vetos, uint256 forEpoch);

    event RegisterInitiative(address initiative, address registrant, uint256 atEpoch, HookStatus hookStatus);
    event UnregisterInitiative(address initiative, uint256 atEpoch, HookStatus hookStatus);

    event AllocateSTAToken(
        address indexed user,
        address indexed initiative,
        int256 deltaVoteSTAToken,
        int256 deltaVetoSTAToken,
        uint256 atEpoch,
        HookStatus hookStatus
    );
    event ClaimForInitiative(address indexed initiative, uint256 one, uint256 forEpoch, HookStatus hookStatus);

    struct Configuration {
        uint256 registrationFee;
        uint256 registrationThresholdFactor;
        uint256 unregistrationThresholdFactor;
        uint256 unregistrationAfterEpochs;
        uint256 votingThresholdFactor;
        uint256 minClaim;
        uint256 minAccrual;
        uint256 epochStart;
        uint256 epochDuration;
        uint256 epochVotingCutoff;
    }

    function registerInitialInitiatives(address[] memory _initiatives) external;

    /// @notice Address of the staking contract
    /// @return stakingContract Address of the staking contract
    function STAKING_CONTRACT() external view returns (ISingleStaking stakingContract);

    /// @notice Address of the STAToken token
    /// @return staToken Address of the STAToken token
    function staToken() external view returns (IERC20 staToken);
    /// @notice Address of the ONE token
    /// @return one Address of the ONE token
    function one() external view returns (IERC20 one);
    /// @notice Timestamp at which the first epoch starts
    /// @return epochStart Timestamp at which the first epoch starts
    function EPOCH_START() external view returns (uint256 epochStart);
    /// @notice Duration of an epoch in seconds (e.g. 1 week)
    /// @return epochDuration Epoch duration
    function EPOCH_DURATION() external view returns (uint256 epochDuration);
    /// @notice Voting period of an epoch in seconds (e.g. 6 days)
    /// @return epochVotingCutoff Epoch voting cutoff
    function EPOCH_VOTING_CUTOFF() external view returns (uint256 epochVotingCutoff);
    /// @notice Minimum ONE amount that has to be claimed, if an initiative doesn't have enough votes to meet the
    /// criteria then it's votes a excluded from the vote count and distribution
    /// @return minClaim Minimum claim amount
    function MIN_CLAIM() external view returns (uint256 minClaim);
    /// @notice Minimum amount of ONE that have to be accrued for an epoch, otherwise accrual will be skipped for
    /// that epoch
    /// @return minAccrual Minimum amount of ONE
    function MIN_ACCRUAL() external view returns (uint256 minAccrual);
    /// @notice Amount of ONE to be paid in order to register a new initiative
    /// @return registrationFee Registration fee
    function REGISTRATION_FEE() external view returns (uint256 registrationFee);
    /// @notice Share of all votes that are necessary to register a new initiative
    /// @return registrationThresholdFactor Threshold factor
    function REGISTRATION_THRESHOLD_FACTOR() external view returns (uint256 registrationThresholdFactor);
    /// @notice Multiple of the voting threshold in vetos that are necessary to unregister an initiative
    /// @return unregistrationThresholdFactor Unregistration threshold factor
    function UNREGISTRATION_THRESHOLD_FACTOR() external view returns (uint256 unregistrationThresholdFactor);
    /// @notice Number of epochs an initiative has to be inactive before it can be unregistered
    /// @return unregistrationAfterEpochs Number of epochs
    function UNREGISTRATION_AFTER_EPOCHS() external view returns (uint256 unregistrationAfterEpochs);
    /// @notice Share of all votes that are necessary for an initiative to be included in the vote count
    /// @return votingThresholdFactor Voting threshold factor
    function VOTING_THRESHOLD_FACTOR() external view returns (uint256 votingThresholdFactor);

    /// @notice Returns the amount of ONE accrued since last epoch (last snapshot)
    /// @return oneAccrued ONE accrued
    function oneAccrued() external view returns (uint256 oneAccrued);

    struct VoteSnapshot {
        uint256 votes; // Votes at epoch transition
        uint256 forEpoch; // Epoch for which the votes are counted
    }

    struct InitiativeVoteSnapshot {
        uint256 votes; // Votes at epoch transition
        uint256 forEpoch; // Epoch for which the votes are counted
        uint256 lastCountedEpoch; // Epoch at which which the votes where counted last in the global snapshot
        uint256 vetos; // Vetos at epoch transition
    }

    /// @notice Returns the vote count snapshot of the previous epoch
    /// @return votes Number of votes
    /// @return forEpoch Epoch for which the votes are counted
    function votesSnapshot() external view returns (uint256 votes, uint256 forEpoch);
    /// @notice Returns the vote count snapshot for an initiative of the previous epoch
    /// @param _initiative Address of the initiative
    /// @return votes Number of votes
    /// @return forEpoch Epoch for which the votes are counted
    /// @return lastCountedEpoch Epoch at which which the votes where counted last in the global snapshot
    function votesForInitiativeSnapshot(address _initiative)
        external
        view
        returns (uint256 votes, uint256 forEpoch, uint256 lastCountedEpoch, uint256 vetos);

    struct Allocation {
        uint256 voteSTAToken; // STAToken allocated vouching for the initiative
        uint256 voteOffset; // Offset associated with STAToken vouching for the initiative
        uint256 vetoSTAToken; // STAToken vetoing the initiative
        uint256 vetoOffset; // Offset associated with STAToken vetoing the initiative
        uint256 atEpoch; // Epoch at which the allocation was last updated
    }

    struct UserState {
        uint256 unallocatedSTAToken; // STAToken deposited and unallocated
        uint256 unallocatedOffset; // The offset sum corresponding to the unallocated STAToken
        uint256 allocatedSTAToken; // STAToken allocated by the user to initatives
        uint256 allocatedOffset; // The offset sum corresponding to the allocated STAToken
        uint256 totalLpToken;
    }

    struct InitiativeState {
        uint256 voteSTAToken; // STAToken allocated vouching for the initiative
        uint256 voteOffset; // Offset associated with STAToken vouching for to the initative
        uint256 vetoSTAToken; // STAToken allocated vetoing the initiative
        uint256 vetoOffset; // Offset associated with STAToken veoting the initative
        uint256 lastEpochClaim;
    }

    struct GlobalState {
        uint256 countedVoteSTAToken; // Total STAToken that is included in vote counting
        uint256 countedVoteOffset; // Offset associated with the counted vote STAToken
    }

    /// @notice Returns the user's state
    /// @return unallocatedSTAToken STAToken deposited and unallocated
    /// @return unallocatedOffset Offset associated with unallocated STAToken
    /// @return allocatedSTAToken allocated by the user to initatives
    /// @return allocatedOffset Offset associated with allocated STAToken
    function userStates(address _user)
        external
        view
        returns (
            uint256 unallocatedSTAToken,
            uint256 unallocatedOffset,
            uint256 allocatedSTAToken,
            uint256 allocatedOffset,
            uint256 totalLpToken
        );
    /// @notice Returns the initiative's state
    /// @param _initiative Address of the initiative
    /// @return voteSTAToken STAToken allocated vouching for the initiative
    /// @return voteOffset Offset associated with voteSTAToken
    /// @return vetoSTAToken STAToken allocated vetoing the initiative
    /// @return vetoOffset Offset associated with vetoSTAToken
    /// @return lastEpochClaim // Last epoch at which rewards were claimed
    function initiativeStates(address _initiative)
        external
        view
        returns (
            uint256 voteSTAToken,
            uint256 voteOffset,
            uint256 vetoSTAToken,
            uint256 vetoOffset,
            uint256 lastEpochClaim
        );
    /// @notice Returns the global state
    /// @return countedVoteSTAToken Total STAToken that is included in vote counting
    /// @return countedVoteOffset Offset associated with countedVoteSTAToken
    function globalState() external view returns (uint256 countedVoteSTAToken, uint256 countedVoteOffset);
    /// @notice Returns the amount of voting and vetoing STAToken a user allocated to an initiative
    /// @param _user Address of the user
    /// @param _initiative Address of the initiative
    /// @return voteSTAToken STAToken allocated vouching for the initiative
    /// @return voteOffset The offset associated with voteSTAToken
    /// @return vetoSTAToken allocated vetoing the initiative
    /// @return vetoOffset the offset associated with vetoSTAToken
    /// @return atEpoch Epoch at which the allocation was last updated
    function staTokenAllocatedByUserToInitiative(address _user, address _initiative)
        external
        view
        returns (uint256 voteSTAToken, uint256 voteOffset, uint256 vetoSTAToken, uint256 vetoOffset, uint256 atEpoch);

    /// @notice Returns when an initiative was registered
    /// @param _initiative Address of the initiative
    /// @return atEpoch If `_initiative` is an active initiative, returns the epoch at which it was registered.
    ///                 If `_initiative` hasn't been registered, returns 0.
    ///                 If `_initiative` has been unregistered, returns `UNREGISTERED_INITIATIVE`.
    function registeredInitiatives(address _initiative) external view returns (uint256 atEpoch);

    /*//////////////////////////////////////////////////////////////
                                STAKING
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposits STAToken
    /// @param _amount Amount of STAToken to deposit
    function deposit(uint256 _amount) external;

    /// @notice Withdraws STAToken
    /// @param _amount Amount of STAToken to withdraw
    function withdraw(uint256 _amount) external;

    /*//////////////////////////////////////////////////////////////
                                 VOTING
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the current epoch number
    /// @return epoch Current epoch
    function epoch() external view returns (uint256 epoch);
    /// @notice Returns the timestamp at which the current epoch started
    /// @return epochStart Epoch start of the current epoch
    function epochStart() external view returns (uint256 epochStart);
    /// @notice Returns the number of seconds that have gone by since the current epoch started
    /// @return secondsWithinEpoch Seconds within the current epoch
    function secondsWithinEpoch() external view returns (uint256 secondsWithinEpoch);

    /// @notice Returns the voting power for an entity (i.e. user or initiative) at a given timestamp
    /// @param _staTokenAmount Amount of STAToken associated with the entity
    /// @param _timestamp Timestamp at which to calculate voting power
    /// @param _offset The entity's offset sum
    /// @return votes Number of votes
    function staTokenToVotes(uint256 _staTokenAmount, uint256 _timestamp, uint256 _offset)
        external
        pure
        returns (uint256);

    /// @dev Returns the most up to date voting threshold
    /// In contrast to `getLatestVotingThreshold` this function updates the snapshot
    /// This ensures that the value returned is always the latest
    function calculateVotingThreshold() external returns (uint256);

    /// @dev Utility function to compute the threshold votes without recomputing the snapshot
    /// Note that `oneAccrued` is a cached value, this function works correctly only when called after an accrual
    function calculateVotingThreshold(uint256 _votes) external view returns (uint256);

    /// @notice Return the most up to date global snapshot and state as well as a flag to notify whether the state can be updated
    /// This is a convenience function to always retrieve the most up to date state values
    function getTotalVotesAndState()
        external
        view
        returns (VoteSnapshot memory snapshot, GlobalState memory state, bool shouldUpdate);

    /// @dev Given an initiative address, return it's most up to date snapshot and state as well as a flag to notify whether the state can be updated
    /// This is a convenience function to always retrieve the most up to date state values
    function getInitiativeSnapshotAndState(address _initiative)
        external
        view
        returns (
            InitiativeVoteSnapshot memory initiativeSnapshot,
            InitiativeState memory initiativeState,
            bool shouldUpdate
        );

    /// @notice Voting threshold is the max. of either:
    ///   - 4% of the total voting STAToken in the previous epoch
    ///   - or the minimum number of votes necessary to claim at least MIN_CLAIM ONE
    /// This value can be offsynch, use the non view `calculateVotingThreshold` to always retrieve the most up to date value
    /// @return votingThreshold Voting threshold
    function getLatestVotingThreshold() external view returns (uint256 votingThreshold);

    /// @notice Snapshots votes for the previous epoch and accrues funds for the current epoch
    /// @param _initiative Address of the initiative
    /// @return voteSnapshot Vote snapshot
    /// @return initiativeVoteSnapshot Vote snapshot of the initiative
    function snapshotVotesForInitiative(address _initiative)
        external
        returns (VoteSnapshot memory voteSnapshot, InitiativeVoteSnapshot memory initiativeVoteSnapshot);

    /*//////////////////////////////////////////////////////////////
                                 FSM
    //////////////////////////////////////////////////////////////*/

    enum InitiativeStatus {
        NONEXISTENT,
        /// This Initiative Doesn't exist | This is never returned
        WARM_UP,
        /// This epoch was just registered
        SKIP,
        /// This epoch will result in no rewards and no unregistering
        CLAIMABLE,
        /// This epoch will result in claiming rewards
        CLAIMED,
        /// The rewards for this epoch have been claimed
        UNREGISTERABLE,
        /// Can be unregistered
        DISABLED // It was already Unregistered

    }

    function getInitiativeState(address _initiative)
        external
        returns (InitiativeStatus status, uint256 lastEpochClaim, uint256 claimableAmount);

    function getInitiativeState(
        address _initiative,
        VoteSnapshot memory _votesSnapshot,
        InitiativeVoteSnapshot memory _votesForInitiativeSnapshot,
        InitiativeState memory _initiativeState
    ) external view returns (InitiativeStatus status, uint256 lastEpochClaim, uint256 claimableAmount);

    /// @notice Registers a new initiative
    /// @param _initiative Address of the initiative
    function registerInitiative(address _initiative) external;
    // /// @notice Unregisters an initiative if it didn't receive enough votes in the last 4 epochs
    // /// or if it received more vetos than votes and the number of vetos are greater than 3 times the voting threshold
    // /// @param _initiative Address of the initiative
    function unregisterInitiative(address _initiative) external;

    /// @notice Allocates the user's STAToken to initiatives
    /// @dev The user can only allocate to active initiatives (older than 1 epoch) and has to have enough unallocated
    /// STAToken available, the initiatives listed must be unique, and towards the end of the epoch a user can only maintain or reduce their votes
    /// @param _initiativesToReset Addresses of the initiatives the caller was previously allocated to, must be reset to prevent desynch of voting power
    /// @param _initiatives Addresses of the initiatives to allocate to, can match or be different from `_resetInitiatives`
    /// @param _absoluteSTATokenVotes STAToken to allocate to the initiatives as votes
    /// @param _absoluteSTATokenVetos STAToken to allocate to the initiatives as vetos
    function allocateSTAToken(
        address[] calldata _initiativesToReset,
        address[] memory _initiatives,
        int256[] memory _absoluteSTATokenVotes,
        int256[] memory _absoluteSTATokenVetos
    ) external;
    /// @notice Deallocates the user's STAToken from initiatives
    /// @param _initiativesToReset Addresses of initiatives to deallocate STAToken from
    /// @param _checkAll When true, the call will revert if there is still some allocated STAToken left after deallocating
    ///                  from all the addresses in `_initiativesToReset`
    function resetAllocations(address[] calldata _initiativesToReset, bool _checkAll) external;

    /// @notice Splits accrued funds according to votes received between all initiatives
    /// @param _initiative Addresse of the initiative
    /// @return claimed Amount of ONE claimed
    function claimForInitiative(address _initiative) external returns (uint256 claimed);
}
