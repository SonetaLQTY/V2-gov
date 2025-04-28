// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IGovernance, UNREGISTERED_INITIATIVE} from "./interfaces/IGovernance.sol";
import {IInitiative} from "./interfaces/IInitiative.sol";

import {add, sub, max} from "./utils/Math.sol";
import {_requireNoDuplicates, _requireNoNegatives} from "./utils/UniqueArray.sol";
import {MultiDelegateCall} from "./utils/MultiDelegateCall.sol";
import {WAD} from "./utils/Types.sol";
import {safeCallWithMinGas} from "./utils/SafeCallMinGas.sol";
import {Ownable} from "./utils/Ownable.sol";
import {_pairSonataToVotes} from "./utils/VotingPower.sol";

/// @title Governance: Modular Initiative based Governance
contract Governance is MultiDelegateCall, Ownable, IGovernance {
    using SafeERC20 for IERC20;

    uint256 constant MIN_GAS_TO_HOOK = 350_000;

    /// Replace this to ensure hooks have sufficient gas

    /// @inheritdoc IGovernance
    IERC20 public immutable one;
    /// @inheritdoc IGovernance
    uint256 public immutable EPOCH_START;
    /// @inheritdoc IGovernance
    uint256 public immutable EPOCH_DURATION;
    /// @inheritdoc IGovernance
    uint256 public immutable EPOCH_VOTING_CUTOFF;
    /// @inheritdoc IGovernance
    uint256 public immutable MIN_CLAIM;
    /// @inheritdoc IGovernance
    uint256 public immutable MIN_ACCRUAL;
    /// @inheritdoc IGovernance
    uint256 public immutable REGISTRATION_FEE;
    /// @inheritdoc IGovernance
    uint256 public immutable REGISTRATION_THRESHOLD_FACTOR;
    /// @inheritdoc IGovernance
    uint256 public immutable UNREGISTRATION_THRESHOLD_FACTOR;
    /// @inheritdoc IGovernance
    uint256 public immutable UNREGISTRATION_AFTER_EPOCHS;
    /// @inheritdoc IGovernance
    uint256 public immutable VOTING_THRESHOLD_FACTOR;

    /// @inheritdoc IGovernance
    IERC20 public pairSonata;
    /// @inheritdoc IGovernance
    uint256 public oneAccrued;

    /// @inheritdoc IGovernance
    VoteSnapshot public votesSnapshot;
    /// @inheritdoc IGovernance
    mapping(address => InitiativeVoteSnapshot) public votesForInitiativeSnapshot;

    /// @inheritdoc IGovernance
    GlobalState public globalState;
    /// @inheritdoc IGovernance
    mapping(address => UserState) public userStates;
    /// @inheritdoc IGovernance
    mapping(address => InitiativeState) public initiativeStates;
    /// @inheritdoc IGovernance
    mapping(address => mapping(address => Allocation)) public pairSonataAllocatedByUserToInitiative;
    /// @inheritdoc IGovernance
    mapping(address => uint256) public override registeredInitiatives;

    mapping(address => uint256) stakes;

    constructor(address _one, Configuration memory _config, address _owner, address[] memory _initiatives)
        Ownable(_owner)
    {
        one = IERC20(_one);
        require(_config.minClaim <= _config.minAccrual, "Gov: min-claim-gt-min-accrual");
        REGISTRATION_FEE = _config.registrationFee;

        // Registration threshold must be below 100% of votes
        require(_config.registrationThresholdFactor < WAD, "Gov: registration-config");
        REGISTRATION_THRESHOLD_FACTOR = _config.registrationThresholdFactor;

        // Unregistration must be X times above the `votingThreshold`
        require(_config.unregistrationThresholdFactor > WAD, "Gov: unregistration-config");
        UNREGISTRATION_THRESHOLD_FACTOR = _config.unregistrationThresholdFactor;
        UNREGISTRATION_AFTER_EPOCHS = _config.unregistrationAfterEpochs;

        // Voting threshold must be below 100% of votes
        require(_config.votingThresholdFactor < WAD, "Gov: voting-config");
        VOTING_THRESHOLD_FACTOR = _config.votingThresholdFactor;

        MIN_CLAIM = _config.minClaim;
        MIN_ACCRUAL = _config.minAccrual;
        require(_config.epochStart <= block.timestamp, "Gov: cannot-start-in-future");
        EPOCH_START = _config.epochStart;
        require(_config.epochDuration > 0, "Gov: epoch-duration-zero");
        EPOCH_DURATION = _config.epochDuration;
        require(_config.epochVotingCutoff < _config.epochDuration, "Gov: epoch-voting-cutoff-gt-epoch-duration");
        EPOCH_VOTING_CUTOFF = _config.epochVotingCutoff;

        if (_initiatives.length > 0) {
            registerInitialInitiatives(_initiatives);
        }
    }

    function registerInitialInitiatives(address[] memory _initiatives) public onlyOwner {
        for (uint256 i = 0; i < _initiatives.length; i++) {
            // Register initial initiatives in the earliest possible epoch, which lets us make them votable immediately
            // post-deployment if we so choose, by backdating the first epoch at least EPOCH_DURATION in the past.
            registeredInitiatives[_initiatives[i]] = 1;

            bool success = safeCallWithMinGas(
                _initiatives[i], MIN_GAS_TO_HOOK, 0, abi.encodeCall(IInitiative.onRegisterInitiative, (1))
            );

            emit RegisterInitiative(_initiatives[i], msg.sender, 1, success ? HookStatus.Succeeded : HookStatus.Failed);
        }
    }

    function enableGovernance(address _lpToken) external onlyOwner {
        pairSonata = IERC20(_lpToken);
        _renounceOwnership();
    }

    /*//////////////////////////////////////////////////////////////
                                STAKING
    //////////////////////////////////////////////////////////////*/

    function _increaseUserVoteTrackers(uint256 _pairSonataAmount) private {
        require(_pairSonataAmount > 0, "Governance: zero-pairSonata-amount");

        // update the vote power trackers
        userStates[msg.sender].unallocatedPairSonata += _pairSonataAmount;
        userStates[msg.sender].unallocatedOffset += block.timestamp * _pairSonataAmount;
    }

    /// @inheritdoc IGovernance
    function depositPairSonata(uint256 _pairSonataAmount) external {
        depositPairSonata(_pairSonataAmount, false, msg.sender);
    }

    function depositPairSonata(uint256 _pairSonataAmount, bool _doSendRewards, address _recipient) public {
        _increaseUserVoteTrackers(_pairSonataAmount);

        pairSonata.safeTransferFrom(msg.sender, address(this), _pairSonataAmount);
        stakes[msg.sender] += _pairSonataAmount;

        emit DepositPairSonata(msg.sender, _recipient, _pairSonataAmount, 0, 0, 0, 0);
    }

    /// @inheritdoc IGovernance
    function withdrawPairSonata(uint256 _pairSonataAmount) external {
        withdrawPairSonata(_pairSonataAmount, msg.sender);
    }

    function withdrawPairSonata(uint256 _pairSonataAmount, address _recipient) public {
        UserState storage userState = userStates[msg.sender];

        // check if user has enough unallocated pairSonata
        require(_pairSonataAmount <= userState.unallocatedPairSonata, "Governance: insufficient-unallocated-pairSonata");

        // Update the offset tracker
        if (_pairSonataAmount < userState.unallocatedPairSonata) {
            // The offset decrease is proportional to the partial pairSonata decrease
            uint256 offsetDecrease = _pairSonataAmount * userState.unallocatedOffset / userState.unallocatedPairSonata;
            userState.unallocatedOffset -= offsetDecrease;
        } else {
            // if _pairSonataAmount == userState.unallocatedPairSonata, zero the offset tracker
            userState.unallocatedOffset = 0;
        }

        // Update the user's PairSonata tracker
        userState.unallocatedPairSonata -= _pairSonataAmount;

        stakes[msg.sender] -= _pairSonataAmount;
        pairSonata.transfer(_recipient, _pairSonataAmount);

        emit WithdrawPairSonata(msg.sender, _recipient, _pairSonataAmount, 0, 0, 0, 0, 0);
    }

    /*//////////////////////////////////////////////////////////////
                                 VOTING
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IGovernance
    function epoch() public view returns (uint256) {
        return ((block.timestamp - EPOCH_START) / EPOCH_DURATION) + 1;
    }

    /// @inheritdoc IGovernance
    function epochStart() public view returns (uint256) {
        return EPOCH_START + (epoch() - 1) * EPOCH_DURATION;
    }

    /// @inheritdoc IGovernance
    function secondsWithinEpoch() public view returns (uint256) {
        return (block.timestamp - EPOCH_START) % EPOCH_DURATION;
    }

    /// @inheritdoc IGovernance
    function pairSonataToVotes(uint256 _pairSonataAmount, uint256 _timestamp, uint256 _offset)
        public
        pure
        returns (uint256)
    {
        return _pairSonataToVotes(_pairSonataAmount, _timestamp, _offset);
    }

    /*//////////////////////////////////////////////////////////////
                                 SNAPSHOTS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IGovernance
    function getLatestVotingThreshold() public view returns (uint256) {
        uint256 snapshotVotes = votesSnapshot.votes;

        return calculateVotingThreshold(snapshotVotes);
    }

    /// @inheritdoc IGovernance
    function calculateVotingThreshold() public returns (uint256) {
        (VoteSnapshot memory snapshot,) = _snapshotVotes();

        return calculateVotingThreshold(snapshot.votes);
    }

    /// @inheritdoc IGovernance
    function calculateVotingThreshold(uint256 _votes) public view returns (uint256) {
        if (_votes == 0) return 0;

        uint256 minVotes; // to reach MIN_CLAIM: snapshotVotes * MIN_CLAIM / oneAccrued
        uint256 payoutPerVote = oneAccrued * WAD / _votes;
        if (payoutPerVote != 0) {
            minVotes = MIN_CLAIM * WAD / payoutPerVote;
        }
        return max(_votes * VOTING_THRESHOLD_FACTOR / WAD, minVotes);
    }

    // Snapshots votes at the end of the previous epoch
    // Accrues funds until the first activity of the current epoch, which are valid throughout all of the current epoch
    function _snapshotVotes() internal returns (VoteSnapshot memory snapshot, GlobalState memory state) {
        bool shouldUpdate;
        (snapshot, state, shouldUpdate) = getTotalVotesAndState();

        if (shouldUpdate) {
            votesSnapshot = snapshot;
            uint256 oneBalance = one.balanceOf(address(this));
            oneAccrued = (oneBalance < MIN_ACCRUAL) ? 0 : oneBalance;
            emit SnapshotVotes(snapshot.votes, snapshot.forEpoch, oneAccrued);
        }
    }

    /// @inheritdoc IGovernance
    function getTotalVotesAndState()
        public
        view
        returns (VoteSnapshot memory snapshot, GlobalState memory state, bool shouldUpdate)
    {
        uint256 currentEpoch = epoch();
        snapshot = votesSnapshot;
        state = globalState;

        if (snapshot.forEpoch < currentEpoch - 1) {
            shouldUpdate = true;

            snapshot.votes = pairSonataToVotes(state.countedVotePairSonata, epochStart(), state.countedVoteOffset);
            snapshot.forEpoch = currentEpoch - 1;
        }
    }

    // Snapshots votes for an initiative for the previous epoch
    function _snapshotVotesForInitiative(address _initiative)
        internal
        returns (InitiativeVoteSnapshot memory initiativeSnapshot, InitiativeState memory initiativeState)
    {
        bool shouldUpdate;
        (initiativeSnapshot, initiativeState, shouldUpdate) = getInitiativeSnapshotAndState(_initiative);

        if (shouldUpdate) {
            votesForInitiativeSnapshot[_initiative] = initiativeSnapshot;
            emit SnapshotVotesForInitiative(
                _initiative, initiativeSnapshot.votes, initiativeSnapshot.vetos, initiativeSnapshot.forEpoch
            );
        }
    }

    /// @inheritdoc IGovernance
    function getInitiativeSnapshotAndState(address _initiative)
        public
        view
        returns (
            InitiativeVoteSnapshot memory initiativeSnapshot,
            InitiativeState memory initiativeState,
            bool shouldUpdate
        )
    {
        // Get the storage data
        uint256 currentEpoch = epoch();
        initiativeSnapshot = votesForInitiativeSnapshot[_initiative];
        initiativeState = initiativeStates[_initiative];

        if (initiativeSnapshot.forEpoch < currentEpoch - 1) {
            shouldUpdate = true;

            uint256 start = epochStart();
            uint256 votes = pairSonataToVotes(initiativeState.votePairSonata, start, initiativeState.voteOffset);
            uint256 vetos = pairSonataToVotes(initiativeState.vetoPairSonata, start, initiativeState.vetoOffset);
            initiativeSnapshot.votes = votes;
            initiativeSnapshot.vetos = vetos;

            initiativeSnapshot.forEpoch = currentEpoch - 1;
        }
    }

    /// @inheritdoc IGovernance
    function snapshotVotesForInitiative(address _initiative)
        external
        returns (VoteSnapshot memory voteSnapshot, InitiativeVoteSnapshot memory initiativeVoteSnapshot)
    {
        (voteSnapshot,) = _snapshotVotes();
        (initiativeVoteSnapshot,) = _snapshotVotesForInitiative(_initiative);
    }

    /*//////////////////////////////////////////////////////////////
                                 FSM
    //////////////////////////////////////////////////////////////*/

    /// @notice Given an inititive address, updates all snapshots and return the initiative state
    ///     See the view version of `getInitiativeState` for the underlying logic on Initatives FSM
    function getInitiativeState(address _initiative)
        public
        returns (InitiativeStatus status, uint256 lastEpochClaim, uint256 claimableAmount)
    {
        (VoteSnapshot memory votesSnapshot_,) = _snapshotVotes();
        (InitiativeVoteSnapshot memory votesForInitiativeSnapshot_, InitiativeState memory initiativeState) =
            _snapshotVotesForInitiative(_initiative);

        return getInitiativeState(_initiative, votesSnapshot_, votesForInitiativeSnapshot_, initiativeState);
    }

    /// @dev Given an initiative address and its snapshot, determines the current state for an initiative
    function getInitiativeState(
        address _initiative,
        VoteSnapshot memory _votesSnapshot,
        InitiativeVoteSnapshot memory _votesForInitiativeSnapshot,
        InitiativeState memory _initiativeState
    ) public view returns (InitiativeStatus status, uint256 lastEpochClaim, uint256 claimableAmount) {
        uint256 initiativeRegistrationEpoch = registeredInitiatives[_initiative];

        // == Non existent Condition == //
        if (initiativeRegistrationEpoch == 0) {
            return (InitiativeStatus.NONEXISTENT, 0, 0);
            /// By definition it has zero rewards
        }

        uint256 currentEpoch = epoch();

        // == Just Registered Condition == //
        if (initiativeRegistrationEpoch == currentEpoch) {
            return (InitiativeStatus.WARM_UP, 0, 0);
            /// Was registered this week, cannot have rewards
        }

        // Fetch last epoch at which we claimed
        lastEpochClaim = initiativeStates[_initiative].lastEpochClaim;

        // == Disabled Condition == //
        if (initiativeRegistrationEpoch == UNREGISTERED_INITIATIVE) {
            return (InitiativeStatus.DISABLED, lastEpochClaim, 0);
            /// By definition it has zero rewards
        }

        // == Already Claimed Condition == //
        if (lastEpochClaim >= currentEpoch - 1) {
            // early return, we have already claimed
            return (InitiativeStatus.CLAIMED, lastEpochClaim, claimableAmount);
        }

        // NOTE: Pass the snapshot value so we get accurate result
        uint256 votingTheshold = calculateVotingThreshold(_votesSnapshot.votes);

        // If it's voted and can get rewards
        // Votes > calculateVotingThreshold
        // == Rewards Conditions (votes can be zero, logic is the same) == //

        // By definition if _votesForInitiativeSnapshot.votes > 0 then _votesSnapshot.votes > 0
        if (
            _votesForInitiativeSnapshot.votes > votingTheshold
                && _votesForInitiativeSnapshot.votes > _votesForInitiativeSnapshot.vetos
        ) {
            uint256 claim = _votesForInitiativeSnapshot.votes * oneAccrued / _votesSnapshot.votes;

            return (InitiativeStatus.CLAIMABLE, lastEpochClaim, claim);
        }

        // == Unregister Condition == //
        // e.g. if `UNREGISTRATION_AFTER_EPOCHS` is 4, the initiative will become unregisterable after spending 4 epochs
        // while being in one of the following conditions:
        //  - in `SKIP` state (not having received enough votes to cross the voting threshold)
        //  - in `CLAIMABLE` state (having received enough votes to cross the voting threshold) but never being claimed
        if (
            (_initiativeState.lastEpochClaim + UNREGISTRATION_AFTER_EPOCHS < currentEpoch - 1)
                || _votesForInitiativeSnapshot.vetos > _votesForInitiativeSnapshot.votes
                    && _votesForInitiativeSnapshot.vetos > votingTheshold * UNREGISTRATION_THRESHOLD_FACTOR / WAD
        ) {
            return (InitiativeStatus.UNREGISTERABLE, lastEpochClaim, 0);
        }

        // == Not meeting threshold Condition == //
        return (InitiativeStatus.SKIP, lastEpochClaim, 0);
    }

    /// @inheritdoc IGovernance
    function registerInitiative(address _initiative) external {
        uint256 currentEpoch = epoch();
        require(currentEpoch > 2, "Governance: registration-not-yet-enabled");

        require(_initiative != address(0), "Governance: zero-address");
        (InitiativeStatus status,,) = getInitiativeState(_initiative);
        require(status == InitiativeStatus.NONEXISTENT, "Governance: initiative-already-registered");

        (VoteSnapshot memory snapshot,) = _snapshotVotes();
        UserState memory userState = userStates[msg.sender];

        one.safeTransferFrom(msg.sender, address(this), REGISTRATION_FEE);

        // an initiative can be registered if the registrant has more voting power (PairSonata * age)
        // than the registration threshold derived from the previous epoch's total global votes

        uint256 upscaledSnapshotVotes = snapshot.votes;

        uint256 totalUserOffset = userState.allocatedOffset + userState.unallocatedOffset;
        require(
            // Check against the user's total voting power, so include both allocated and unallocated PairSonata
            pairSonataToVotes(stakes[msg.sender], epochStart(), totalUserOffset)
                >= upscaledSnapshotVotes * REGISTRATION_THRESHOLD_FACTOR / WAD,
            "Governance: insufficient-pairSonata"
        );

        registeredInitiatives[_initiative] = currentEpoch;

        /// This ensures that the initiatives has UNREGISTRATION_AFTER_EPOCHS even after the first epoch
        initiativeStates[_initiative].lastEpochClaim = currentEpoch - 1;

        // Replaces try / catch | Enforces sufficient gas is passed
        bool success = safeCallWithMinGas(
            _initiative, MIN_GAS_TO_HOOK, 0, abi.encodeCall(IInitiative.onRegisterInitiative, (currentEpoch))
        );

        emit RegisterInitiative(
            _initiative, msg.sender, currentEpoch, success ? HookStatus.Succeeded : HookStatus.Failed
        );
    }

    struct ResetInitiativeData {
        address initiative;
        int256 PairSonataVotes;
        int256 PairSonataVetos;
        int256 OffsetVotes;
        int256 OffsetVetos;
    }

    /// @dev Resets an initiative and return the previous votes
    /// NOTE: Technically we don't need vetos
    /// NOTE: Technically we want to populate the `ResetInitiativeData` only when `secondsWithinEpoch() > EPOCH_VOTING_CUTOFF`
    function _resetInitiatives(address[] calldata _initiativesToReset)
        internal
        returns (ResetInitiativeData[] memory)
    {
        ResetInitiativeData[] memory cachedData = new ResetInitiativeData[](_initiativesToReset.length);

        int256[] memory deltaPairSonataVotes = new int256[](_initiativesToReset.length);
        int256[] memory deltaPairSonataVetos = new int256[](_initiativesToReset.length);
        int256[] memory deltaOffsetVotes = new int256[](_initiativesToReset.length);
        int256[] memory deltaOffsetVetos = new int256[](_initiativesToReset.length);

        // Prepare reset data
        for (uint256 i; i < _initiativesToReset.length; i++) {
            Allocation memory alloc = pairSonataAllocatedByUserToInitiative[msg.sender][_initiativesToReset[i]];
            require(alloc.votePairSonata > 0 || alloc.vetoPairSonata > 0, "Governance: nothing to reset");

            // Cache, used to enforce limits later
            cachedData[i] = ResetInitiativeData({
                initiative: _initiativesToReset[i],
                PairSonataVotes: int256(alloc.votePairSonata),
                PairSonataVetos: int256(alloc.vetoPairSonata),
                OffsetVotes: int256(alloc.voteOffset),
                OffsetVetos: int256(alloc.vetoOffset)
            });

            // -0 is still 0, so its fine to flip both
            deltaPairSonataVotes[i] = -(cachedData[i].PairSonataVotes);
            deltaPairSonataVetos[i] = -(cachedData[i].PairSonataVetos);
            deltaOffsetVotes[i] = -(cachedData[i].OffsetVotes);
            deltaOffsetVetos[i] = -(cachedData[i].OffsetVetos);
        }

        // RESET HERE || All initiatives will receive most updated data and 0 votes / vetos
        _allocatePairSonata(
            _initiativesToReset, deltaPairSonataVotes, deltaPairSonataVetos, deltaOffsetVotes, deltaOffsetVetos
        );

        return cachedData;
    }

    /// @inheritdoc IGovernance
    function resetAllocations(address[] calldata _initiativesToReset, bool checkAll) external {
        _requireNoDuplicates(_initiativesToReset);
        _resetInitiatives(_initiativesToReset);

        // NOTE: In most cases, the check will pass
        // But if you allocate too many initiatives, we may run OOG
        // As such the check is optional here
        // All other calls to the system enforce this
        // So it's recommended that your last call to `resetAllocations` passes the check
        if (checkAll) {
            require(userStates[msg.sender].allocatedPairSonata == 0, "Governance: must be a reset");
        }
    }

    /// @inheritdoc IGovernance
    function allocatePairSonata(
        address[] calldata _initiativesToReset,
        address[] calldata _initiatives,
        int256[] calldata _absolutePairSonataVotes,
        int256[] calldata _absolutePairSonataVetos
    ) external {
        require(
            _initiatives.length == _absolutePairSonataVotes.length
                && _absolutePairSonataVotes.length == _absolutePairSonataVetos.length,
            "Governance: array-length-mismatch"
        );

        // To ensure the change is safe, enforce uniqueness
        _requireNoDuplicates(_initiativesToReset);
        _requireNoDuplicates(_initiatives);

        // Explicit >= 0 checks for all values since we reset values below
        _requireNoNegatives(_absolutePairSonataVotes);
        _requireNoNegatives(_absolutePairSonataVetos);
        // If the goal is to remove all votes from an initiative, including in _initiativesToReset is enough
        _requireNoNOP(_absolutePairSonataVotes, _absolutePairSonataVetos);
        _requireNoSimultaneousVoteAndVeto(_absolutePairSonataVotes, _absolutePairSonataVetos);

        // You MUST always reset
        ResetInitiativeData[] memory cachedData = _resetInitiatives(_initiativesToReset);

        /// Invariant, 0 allocated = 0 votes
        UserState memory userState = userStates[msg.sender];
        require(userState.allocatedPairSonata == 0, "must be a reset");
        require(userState.unallocatedPairSonata != 0, "Governance: insufficient-or-allocated-pairSonata"); // avoid div-by-zero

        // After cutoff you can only re-apply the same vote
        // Or vote less
        // Or abstain
        // You can always add a veto, hence we only validate the addition of Votes
        // And ignore the addition of vetos
        // Validate the data here to ensure that the voting is capped at the amount in the other case
        if (secondsWithinEpoch() > EPOCH_VOTING_CUTOFF) {
            // Cap the max votes to the previous cache value
            // This means that no new votes can happen here

            // Removing and VETOING is always accepted
            for (uint256 x; x < _initiatives.length; x++) {
                // If we find it, we ensure it cannot be an increase
                bool found;
                for (uint256 y; y < cachedData.length; y++) {
                    if (cachedData[y].initiative == _initiatives[x]) {
                        found = true;
                        require(_absolutePairSonataVotes[x] <= cachedData[y].PairSonataVotes, "Cannot increase");
                        break;
                    }
                }

                // Else we assert that the change is a veto, because by definition the initiatives will have received zero votes past this line
                if (!found) {
                    require(_absolutePairSonataVotes[x] == 0, "Must be zero for new initiatives");
                }
            }
        }

        int256[] memory absoluteOffsetVotes = new int256[](_initiatives.length);
        int256[] memory absoluteOffsetVetos = new int256[](_initiatives.length);

        // Calculate the offset portions that correspond to each PairSonata vote and veto portion
        // By recalculating `unallocatedPairSonata` & `unallocatedOffset` after each step, we ensure that rounding error
        // doesn't accumulate in `unallocatedOffset`.
        // However, it should be noted that this makes the exact offset allocations dependent on the ordering of the
        // `_initiatives` array.
        for (uint256 x; x < _initiatives.length; x++) {
            // Either _absolutePairSonataVotes[x] or _absolutePairSonataVetos[x] is guaranteed to be zero
            (int256[] calldata pairSonataAmounts, int256[] memory offsets) = _absolutePairSonataVotes[x] > 0
                ? (_absolutePairSonataVotes, absoluteOffsetVotes)
                : (_absolutePairSonataVetos, absoluteOffsetVetos);

            uint256 pairSonataAmount = uint256(pairSonataAmounts[x]);
            uint256 offset = userState.unallocatedOffset * pairSonataAmount / userState.unallocatedPairSonata;

            userState.unallocatedPairSonata -= pairSonataAmount;
            userState.unallocatedOffset -= offset;

            offsets[x] = int256(offset);
        }

        // Vote here, all values are now absolute changes
        _allocatePairSonata(
            _initiatives, _absolutePairSonataVotes, _absolutePairSonataVetos, absoluteOffsetVotes, absoluteOffsetVetos
        );
    }

    // Avoid "stack too deep" by placing these variables in memory
    struct AllocatePairSonataMemory {
        VoteSnapshot votesSnapshot_;
        GlobalState state;
        UserState userState;
        InitiativeVoteSnapshot votesForInitiativeSnapshot_;
        InitiativeState initiativeState;
        InitiativeState prevInitiativeState;
        Allocation allocation;
        uint256 currentEpoch;
        int256 deltaPairSonataVotes;
        int256 deltaPairSonataVetos;
        int256 deltaOffsetVotes;
        int256 deltaOffsetVetos;
    }

    /// @dev For each given initiative applies relative changes to the allocation
    /// @dev Assumes that all the input arrays are of equal length
    /// @dev NOTE: Given the current usage the function either: Resets the value to 0, or sets the value to a new value
    ///      Review the flows as the function could be used in many ways, but it ends up being used in just those 2 ways
    function _allocatePairSonata(
        address[] memory _initiatives,
        int256[] memory _deltaPairSonataVotes,
        int256[] memory _deltaPairSonataVetos,
        int256[] memory _deltaOffsetVotes,
        int256[] memory _deltaOffsetVetos
    ) internal {
        AllocatePairSonataMemory memory vars;
        (vars.votesSnapshot_, vars.state) = _snapshotVotes();
        vars.currentEpoch = epoch();
        vars.userState = userStates[msg.sender];

        for (uint256 i = 0; i < _initiatives.length; i++) {
            address initiative = _initiatives[i];
            vars.deltaPairSonataVotes = _deltaPairSonataVotes[i];
            vars.deltaPairSonataVetos = _deltaPairSonataVetos[i];
            assert(vars.deltaPairSonataVotes != 0 || vars.deltaPairSonataVetos != 0);

            vars.deltaOffsetVotes = _deltaOffsetVotes[i];
            vars.deltaOffsetVetos = _deltaOffsetVetos[i];

            /// === Check FSM === ///
            // Can vote positively in SKIP, CLAIMABLE and CLAIMED states
            // Force to remove votes if disabled
            // Can remove votes and vetos in every stage
            (vars.votesForInitiativeSnapshot_, vars.initiativeState) = _snapshotVotesForInitiative(initiative);

            (InitiativeStatus status,,) = getInitiativeState(
                initiative, vars.votesSnapshot_, vars.votesForInitiativeSnapshot_, vars.initiativeState
            );

            if (vars.deltaPairSonataVotes > 0 || vars.deltaPairSonataVetos > 0) {
                /// You cannot vote on `unregisterable` but a vote may have been there
                require(
                    status == InitiativeStatus.SKIP || status == InitiativeStatus.CLAIMABLE
                        || status == InitiativeStatus.CLAIMED,
                    "Governance: active-vote-fsm"
                );
            }

            if (status == InitiativeStatus.DISABLED) {
                require(vars.deltaPairSonataVotes <= 0 && vars.deltaPairSonataVetos <= 0, "Must be a withdrawal");
            }

            /// === UPDATE ACCOUNTING === ///
            // == INITIATIVE STATE == //

            // deep copy of the initiative's state before the allocation
            vars.prevInitiativeState = InitiativeState(
                vars.initiativeState.votePairSonata,
                vars.initiativeState.voteOffset,
                vars.initiativeState.vetoPairSonata,
                vars.initiativeState.vetoOffset,
                vars.initiativeState.lastEpochClaim
            );

            // allocate the voting and vetoing PairSonata to the initiative
            vars.initiativeState.votePairSonata = add(vars.initiativeState.votePairSonata, vars.deltaPairSonataVotes);
            vars.initiativeState.vetoPairSonata = add(vars.initiativeState.vetoPairSonata, vars.deltaPairSonataVetos);

            // Update the initiative's vote and veto offsets
            vars.initiativeState.voteOffset = add(vars.initiativeState.voteOffset, vars.deltaOffsetVotes);
            vars.initiativeState.vetoOffset = add(vars.initiativeState.vetoOffset, vars.deltaOffsetVetos);

            // update the initiative's state
            initiativeStates[initiative] = vars.initiativeState;

            // == GLOBAL STATE == //

            /// We update the state only for non-disabled initiatives
            /// Disabled initiatves have had their totals subtracted already
            if (status != InitiativeStatus.DISABLED) {
                assert(vars.state.countedVotePairSonata >= vars.prevInitiativeState.votePairSonata);

                // Remove old initative PairSonata and offset from global count
                vars.state.countedVotePairSonata -= vars.prevInitiativeState.votePairSonata;
                vars.state.countedVoteOffset -= vars.prevInitiativeState.voteOffset;

                // Add new initative PairSonata and offset to global count
                vars.state.countedVotePairSonata += vars.initiativeState.votePairSonata;
                vars.state.countedVoteOffset += vars.initiativeState.voteOffset;
            }

            // == USER ALLOCATION TO INITIATIVE == //

            // Record the vote and veto PairSonata and offsets by user to initative
            vars.allocation = pairSonataAllocatedByUserToInitiative[msg.sender][initiative];
            // Update offsets
            vars.allocation.voteOffset = add(vars.allocation.voteOffset, vars.deltaOffsetVotes);
            vars.allocation.vetoOffset = add(vars.allocation.vetoOffset, vars.deltaOffsetVetos);

            // Update votes and vetos
            vars.allocation.votePairSonata = add(vars.allocation.votePairSonata, vars.deltaPairSonataVotes);
            vars.allocation.vetoPairSonata = add(vars.allocation.vetoPairSonata, vars.deltaPairSonataVetos);

            vars.allocation.atEpoch = vars.currentEpoch;

            // Voting power allocated to initiatives should never be negative, else it might break reward allocation
            // schemes such as `BribeInitiative` which distribute rewards in proportion to voting power allocated.
            assert(vars.allocation.votePairSonata * block.timestamp >= vars.allocation.voteOffset);
            assert(vars.allocation.vetoPairSonata * block.timestamp >= vars.allocation.vetoOffset);

            pairSonataAllocatedByUserToInitiative[msg.sender][initiative] = vars.allocation;

            // == USER STATE == //

            // Remove from the user's unallocated PairSonata and offset
            vars.userState.unallocatedPairSonata =
                sub(vars.userState.unallocatedPairSonata, (vars.deltaPairSonataVotes + vars.deltaPairSonataVetos));
            vars.userState.unallocatedOffset =
                sub(vars.userState.unallocatedOffset, (vars.deltaOffsetVotes + vars.deltaOffsetVetos));

            // Add to the user's allocated PairSonata and offset
            vars.userState.allocatedPairSonata =
                add(vars.userState.allocatedPairSonata, (vars.deltaPairSonataVotes + vars.deltaPairSonataVetos));
            vars.userState.allocatedOffset =
                add(vars.userState.allocatedOffset, (vars.deltaOffsetVotes + vars.deltaOffsetVetos));

            HookStatus hookStatus;

            // See https://github.com/liquity/V2-gov/issues/125
            // A malicious initiative could try to dissuade voters from casting vetos by consuming as much gas as
            // possible in the `onAfterAllocatePairSonata` hook when detecting vetos.
            // We deem that the risks of calling into malicous initiatives upon veto allocation far outweigh the
            // benefits of notifying benevolent initiatives of vetos.
            if (vars.allocation.vetoPairSonata == 0) {
                // Replaces try / catch | Enforces sufficient gas is passed
                hookStatus = safeCallWithMinGas(
                    initiative,
                    MIN_GAS_TO_HOOK,
                    0,
                    abi.encodeCall(
                        IInitiative.onAfterAllocatePairSonata,
                        (vars.currentEpoch, msg.sender, vars.userState, vars.allocation, vars.initiativeState)
                    )
                ) ? HookStatus.Succeeded : HookStatus.Failed;
            } else {
                hookStatus = HookStatus.NotCalled;
            }

            emit AllocatePairSonata(
                msg.sender,
                initiative,
                vars.deltaPairSonataVotes,
                vars.deltaPairSonataVetos,
                vars.currentEpoch,
                hookStatus
            );
        }

        require(
            vars.userState.allocatedPairSonata <= stakes[msg.sender], "Governance: insufficient-or-allocated-pairSonata"
        );

        globalState = vars.state;
        userStates[msg.sender] = vars.userState;
    }

    /// @inheritdoc IGovernance
    function unregisterInitiative(address _initiative) external {
        /// Enforce FSM
        (VoteSnapshot memory votesSnapshot_, GlobalState memory state) = _snapshotVotes();
        (InitiativeVoteSnapshot memory votesForInitiativeSnapshot_, InitiativeState memory initiativeState) =
            _snapshotVotesForInitiative(_initiative);

        (InitiativeStatus status,,) =
            getInitiativeState(_initiative, votesSnapshot_, votesForInitiativeSnapshot_, initiativeState);
        require(status == InitiativeStatus.UNREGISTERABLE, "Governance: cannot-unregister-initiative");

        // Remove weight from current state
        uint256 currentEpoch = epoch();

        // NOTE: Safe to remove | See `check_claim_soundness`
        assert(initiativeState.lastEpochClaim < currentEpoch - 1);

        assert(state.countedVotePairSonata >= initiativeState.votePairSonata);
        assert(state.countedVoteOffset >= initiativeState.voteOffset);

        state.countedVotePairSonata -= initiativeState.votePairSonata;
        state.countedVoteOffset -= initiativeState.voteOffset;

        globalState = state;

        /// Epoch will never reach 2^256 - 1
        registeredInitiatives[_initiative] = UNREGISTERED_INITIATIVE;

        // Replaces try / catch | Enforces sufficient gas is passed
        bool success = safeCallWithMinGas(
            _initiative, MIN_GAS_TO_HOOK, 0, abi.encodeCall(IInitiative.onUnregisterInitiative, (currentEpoch))
        );

        emit UnregisterInitiative(_initiative, currentEpoch, success ? HookStatus.Succeeded : HookStatus.Failed);
    }

    /// @inheritdoc IGovernance
    function claimForInitiative(address _initiative) external returns (uint256) {
        // Accrue and update state
        (VoteSnapshot memory votesSnapshot_,) = _snapshotVotes();
        (InitiativeVoteSnapshot memory votesForInitiativeSnapshot_, InitiativeState memory initiativeState) =
            _snapshotVotesForInitiative(_initiative);

        // Compute values on accrued state
        (InitiativeStatus status,, uint256 claimableAmount) =
            getInitiativeState(_initiative, votesSnapshot_, votesForInitiativeSnapshot_, initiativeState);

        if (status != InitiativeStatus.CLAIMABLE) {
            return 0;
        }

        /// INVARIANT: You can only claim for previous epoch
        assert(votesSnapshot_.forEpoch == epoch() - 1);

        /// All unclaimed rewards are always recycled
        /// Invariant `lastEpochClaim` is < epoch() - 1; |
        /// If `lastEpochClaim` is older than epoch() - 1 it means the initiative couldn't claim any rewards this epoch
        initiativeStates[_initiative].lastEpochClaim = epoch() - 1;

        /// INVARIANT, because of rounding errors the system can overpay
        /// We upscale the timestamp to reduce the impact of the loss
        /// However this is still possible
        uint256 available = one.balanceOf(address(this));
        if (claimableAmount > available) {
            claimableAmount = available;
        }

        one.safeTransfer(_initiative, claimableAmount);

        // Replaces try / catch | Enforces sufficient gas is passed
        bool success = safeCallWithMinGas(
            _initiative,
            MIN_GAS_TO_HOOK,
            0,
            abi.encodeCall(IInitiative.onClaimForInitiative, (votesSnapshot_.forEpoch, claimableAmount))
        );

        emit ClaimForInitiative(
            _initiative, claimableAmount, votesSnapshot_.forEpoch, success ? HookStatus.Succeeded : HookStatus.Failed
        );

        return claimableAmount;
    }

    function _requireNoNOP(int256[] memory _absolutePairSonataVotes, int256[] memory _absolutePairSonataVetos)
        internal
        pure
    {
        for (uint256 i; i < _absolutePairSonataVotes.length; i++) {
            require(_absolutePairSonataVotes[i] > 0 || _absolutePairSonataVetos[i] > 0, "Governance: voting nothing");
        }
    }

    function _requireNoSimultaneousVoteAndVeto(
        int256[] memory _absolutePairSonataVotes,
        int256[] memory _absolutePairSonataVetos
    ) internal pure {
        for (uint256 i; i < _absolutePairSonataVotes.length; i++) {
            require(_absolutePairSonataVotes[i] == 0 || _absolutePairSonataVetos[i] == 0, "Governance: vote-and-veto");
        }
    }
}
