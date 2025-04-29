// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IGovernance, UNREGISTERED_INITIATIVE} from "./interfaces/IGovernance.sol";
import {IInitiative} from "./interfaces/IInitiative.sol";
import {IBribeInitiative} from "./interfaces/IBribeInitiative.sol";

import {DoubleLinkedList} from "./utils/DoubleLinkedList.sol";
import {_pairSonataToVotes} from "./utils/VotingPower.sol";

contract BribeInitiative is IInitiative, IBribeInitiative {
    using SafeERC20 for IERC20;
    using DoubleLinkedList for DoubleLinkedList.List;

    uint256 internal immutable EPOCH_START;
    uint256 internal immutable EPOCH_DURATION;

    /// @inheritdoc IBribeInitiative
    IGovernance public immutable governance;
    /// @inheritdoc IBribeInitiative
    IERC20 public immutable one;
    /// @inheritdoc IBribeInitiative
    IERC20 public immutable bribeToken;

    /// @inheritdoc IBribeInitiative
    mapping(uint256 => Bribe) public bribeByEpoch;
    /// @inheritdoc IBribeInitiative
    mapping(address => mapping(uint256 => bool)) public claimedBribeAtEpoch;

    /// Double linked list of the total PairSonata allocated at a given epoch
    DoubleLinkedList.List internal totalPairSonataAllocationByEpoch;
    /// Double linked list of PairSonata allocated by a user at a given epoch
    mapping(address => DoubleLinkedList.List) internal pairSonataAllocationByUserAtEpoch;

    constructor(address _governance, address _one, address _bribeToken) {
        require(_bribeToken != _one, "BribeInitiative: bribe-token-cannot-be-one");

        governance = IGovernance(_governance);
        one = IERC20(_one);
        bribeToken = IERC20(_bribeToken);

        EPOCH_START = governance.EPOCH_START();
        EPOCH_DURATION = governance.EPOCH_DURATION();
    }

    modifier onlyGovernance() {
        require(msg.sender == address(governance), "BribeInitiative: invalid-sender");
        _;
    }

    /// @inheritdoc IBribeInitiative
    function totalPairSonataAllocatedByEpoch(uint256 _epoch) external view returns (uint256, uint256) {
        return (
            totalPairSonataAllocationByEpoch.items[_epoch].pairSonata,
            totalPairSonataAllocationByEpoch.items[_epoch].offset
        );
    }

    /// @inheritdoc IBribeInitiative
    function pairSonataAllocatedByUserAtEpoch(address _user, uint256 _epoch) external view returns (uint256, uint256) {
        return (
            pairSonataAllocationByUserAtEpoch[_user].items[_epoch].pairSonata,
            pairSonataAllocationByUserAtEpoch[_user].items[_epoch].offset
        );
    }

    /// @inheritdoc IBribeInitiative
    function depositBribe(uint256 _oneAmount, uint256 _bribeTokenAmount, uint256 _epoch) external {
        uint256 epoch = governance.epoch();
        require(_epoch >= epoch, "BribeInitiative: now-or-future-epochs");

        bribeByEpoch[_epoch].remainingOneAmount += _oneAmount;
        bribeByEpoch[_epoch].remainingBribeTokenAmount += _bribeTokenAmount;

        emit DepositBribe(msg.sender, _oneAmount, _bribeTokenAmount, _epoch);

        one.safeTransferFrom(msg.sender, address(this), _oneAmount);
        bribeToken.safeTransferFrom(msg.sender, address(this), _bribeTokenAmount);
    }

    function _claimBribe(
        address _user,
        uint256 _epoch,
        uint256 _prevPairSonataAllocationEpoch,
        uint256 _prevTotalPairSonataAllocationEpoch
    ) internal returns (uint256 oneAmount, uint256 bribeTokenAmount) {
        require(_epoch < governance.epoch(), "BribeInitiative: cannot-claim-for-current-epoch");
        require(!claimedBribeAtEpoch[_user][_epoch], "BribeInitiative: already-claimed");

        Bribe memory bribe = bribeByEpoch[_epoch];
        require(bribe.remainingOneAmount != 0 || bribe.remainingBribeTokenAmount != 0, "BribeInitiative: no-bribe");

        DoubleLinkedList.Item memory pairSonataAllocation =
            pairSonataAllocationByUserAtEpoch[_user].getItem(_prevPairSonataAllocationEpoch);

        require(
            _prevPairSonataAllocationEpoch <= _epoch
                && (pairSonataAllocation.next > _epoch || pairSonataAllocation.next == 0),
            "BribeInitiative: invalid-prev-pairSonata-allocation-epoch"
        );
        DoubleLinkedList.Item memory totalPairSonataAllocation =
            totalPairSonataAllocationByEpoch.getItem(_prevTotalPairSonataAllocationEpoch);
        require(
            _prevTotalPairSonataAllocationEpoch <= _epoch
                && (totalPairSonataAllocation.next > _epoch || totalPairSonataAllocation.next == 0),
            "BribeInitiative: invalid-prev-total-pairSonata-allocation-epoch"
        );

        require(totalPairSonataAllocation.pairSonata > 0, "BribeInitiative: total-pairSonata-allocation-zero");
        require(pairSonataAllocation.pairSonata > 0, "BribeInitiative: pairSonata-allocation-zero");

        // `Governance` guarantees that `votes` evaluates to 0 or greater for each initiative at the time of allocation.
        // Since the last possible moment to allocate within this epoch is 1 second before `epochEnd`, we have that:
        //  - `pairSonataAllocation.pairSonata > 0` implies `votes > 0`
        //  - `totalPairSonataAllocation.pairSonata > 0` implies `totalVotes > 0`

        uint256 epochEnd = EPOCH_START + _epoch * EPOCH_DURATION;
        uint256 totalVotes =
            _pairSonataToVotes(totalPairSonataAllocation.pairSonata, epochEnd, totalPairSonataAllocation.offset);
        uint256 votes = _pairSonataToVotes(pairSonataAllocation.pairSonata, epochEnd, pairSonataAllocation.offset);
        uint256 remainingVotes = totalVotes - bribe.claimedVotes;

        oneAmount = bribe.remainingOneAmount * votes / remainingVotes;
        bribeTokenAmount = bribe.remainingBribeTokenAmount * votes / remainingVotes;
        bribe.remainingOneAmount -= oneAmount;
        bribe.remainingBribeTokenAmount -= bribeTokenAmount;
        bribe.claimedVotes += votes;

        bribeByEpoch[_epoch] = bribe;
        claimedBribeAtEpoch[_user][_epoch] = true;

        emit ClaimBribe(_user, _epoch, oneAmount, bribeTokenAmount);
    }

    /// @inheritdoc IBribeInitiative
    function claimBribes(ClaimData[] calldata _claimData)
        external
        returns (uint256 oneAmount, uint256 bribeTokenAmount)
    {
        for (uint256 i = 0; i < _claimData.length; i++) {
            ClaimData memory claimData = _claimData[i];
            (uint256 oneAmount_, uint256 bribeTokenAmount_) = _claimBribe(
                msg.sender,
                claimData.epoch,
                claimData.prevPairSonataAllocationEpoch,
                claimData.prevTotalPairSonataAllocationEpoch
            );
            oneAmount += oneAmount_;
            bribeTokenAmount += bribeTokenAmount_;
        }

        if (oneAmount != 0) one.safeTransfer(msg.sender, oneAmount);
        if (bribeTokenAmount != 0) bribeToken.safeTransfer(msg.sender, bribeTokenAmount);
    }

    /// @inheritdoc IInitiative
    function onRegisterInitiative(uint256) external virtual override onlyGovernance {}

    /// @inheritdoc IInitiative
    function onUnregisterInitiative(uint256) external virtual override onlyGovernance {}

    function _setTotalPairSonataAllocationByEpoch(uint256 _epoch, uint256 _pairSonata, uint256 _offset, bool _insert)
        private
    {
        if (_insert) {
            totalPairSonataAllocationByEpoch.insert(_epoch, _pairSonata, _offset, 0);
        } else {
            totalPairSonataAllocationByEpoch.items[_epoch].pairSonata = _pairSonata;
            totalPairSonataAllocationByEpoch.items[_epoch].offset = _offset;
        }
        emit ModifyTotalPairSonataAllocation(_epoch, _pairSonata, _offset);
    }

    function _setPairSonataAllocationByUserAtEpoch(
        address _user,
        uint256 _epoch,
        uint256 _pairSonata,
        uint256 _offset,
        bool _insert
    ) private {
        if (_insert) {
            pairSonataAllocationByUserAtEpoch[_user].insert(_epoch, _pairSonata, _offset, 0);
        } else {
            pairSonataAllocationByUserAtEpoch[_user].items[_epoch].pairSonata = _pairSonata;
            pairSonataAllocationByUserAtEpoch[_user].items[_epoch].offset = _offset;
        }
        emit ModifyPairSonataAllocation(_user, _epoch, _pairSonata, _offset);
    }

    /// @inheritdoc IBribeInitiative
    function getMostRecentUserEpoch(address _user) external view returns (uint256) {
        uint256 mostRecentUserEpoch = pairSonataAllocationByUserAtEpoch[_user].getHead();

        return mostRecentUserEpoch;
    }

    /// @inheritdoc IBribeInitiative
    function getMostRecentTotalEpoch() external view returns (uint256) {
        uint256 mostRecentTotalEpoch = totalPairSonataAllocationByEpoch.getHead();

        return mostRecentTotalEpoch;
    }

    function onAfterAllocatePairSonata(
        uint256 _currentEpoch,
        address _user,
        IGovernance.UserState calldata,
        IGovernance.Allocation calldata _allocation,
        IGovernance.InitiativeState calldata _initiativeState
    ) external virtual onlyGovernance {
        uint256 mostRecentUserEpoch = pairSonataAllocationByUserAtEpoch[_user].getHead();
        uint256 mostRecentTotalEpoch = totalPairSonataAllocationByEpoch.getHead();

        _setTotalPairSonataAllocationByEpoch(
            _currentEpoch,
            _initiativeState.votePairSonata,
            _initiativeState.voteOffset,
            mostRecentTotalEpoch != _currentEpoch // Insert if current > recent
        );

        _setPairSonataAllocationByUserAtEpoch(
            _user,
            _currentEpoch,
            _allocation.votePairSonata,
            _allocation.voteOffset,
            mostRecentUserEpoch != _currentEpoch // Insert if user current > recent
        );
    }

    /// @inheritdoc IInitiative
    function onClaimForInitiative(uint256, uint256) external virtual override onlyGovernance {}
}
