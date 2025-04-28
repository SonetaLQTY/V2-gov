// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC20Permit} from "openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

import {IUserProxy} from "./interfaces/IUserProxy.sol";
import {IPairSonataStaking} from "./interfaces/IPairSonataStaking.sol";
import {PermitParams} from "./utils/Types.sol";

contract UserProxy is IUserProxy {
    /// @inheritdoc IUserProxy
    IERC20 public immutable pairSonata;
    /// @inheritdoc IUserProxy
    IERC20 public immutable lusd;

    /// @inheritdoc IUserProxy
    IPairSonataStaking public immutable stakingV1;
    /// @inheritdoc IUserProxy
    address public immutable stakingV2;

    constructor(address _pairSonata, address _lusd, address _stakingV1) {
        pairSonata = IERC20(_pairSonata);
        lusd = IERC20(_lusd);
        stakingV1 = IPairSonataStaking(_stakingV1);
        stakingV2 = msg.sender;
    }

    modifier onlyStakingV2() {
        require(msg.sender == stakingV2, "UserProxy: caller-not-stakingV2");
        _;
    }

    /// @inheritdoc IUserProxy
    function stake(uint256 _amount, address _pairSonataFrom, bool _doSendRewards, address _recipient)
        public
        onlyStakingV2
        returns (uint256 lusdReceived, uint256 lusdSent, uint256 ethReceived, uint256 ethSent)
    {
        uint256 initialLUSDAmount = lusd.balanceOf(address(this));
        uint256 initialETHAmount = address(this).balance;

        pairSonata.transferFrom(_pairSonataFrom, address(this), _amount);
        stakingV1.stake(_amount);

        uint256 lusdAmount = lusd.balanceOf(address(this));
        uint256 ethAmount = address(this).balance;

        lusdReceived = lusdAmount - initialLUSDAmount;
        ethReceived = ethAmount - initialETHAmount;

        if (_doSendRewards) (lusdSent, ethSent) = _sendRewards(_recipient, lusdAmount, ethAmount);
    }

    /// @inheritdoc IUserProxy
    function stakeViaPermit(
        uint256 _amount,
        address _pairSonataFrom,
        PermitParams calldata _permitParams,
        bool _doSendRewards,
        address _recipient
    ) external onlyStakingV2 returns (uint256 lusdReceived, uint256 lusdSent, uint256 ethReceived, uint256 ethSent) {
        require(_pairSonataFrom == _permitParams.owner, "UserProxy: owner-not-sender");

        try IERC20Permit(address(pairSonata)).permit(
            _permitParams.owner,
            _permitParams.spender,
            _permitParams.value,
            _permitParams.deadline,
            _permitParams.v,
            _permitParams.r,
            _permitParams.s
        ) {} catch {}

        return stake(_amount, _pairSonataFrom, _doSendRewards, _recipient);
    }

    /// @inheritdoc IUserProxy
    function unstake(uint256 _amount, bool _doSendRewards, address _recipient)
        external
        onlyStakingV2
        returns (
            uint256 pairSonataReceived,
            uint256 pairSonataSent,
            uint256 lusdReceived,
            uint256 lusdSent,
            uint256 ethReceived,
            uint256 ethSent
        )
    {
        uint256 initialPairSonataAmount = pairSonata.balanceOf(address(this));
        uint256 initialLUSDAmount = lusd.balanceOf(address(this));
        uint256 initialETHAmount = address(this).balance;

        stakingV1.unstake(_amount);

        pairSonataSent = pairSonata.balanceOf(address(this));
        uint256 lusdAmount = lusd.balanceOf(address(this));
        uint256 ethAmount = address(this).balance;

        pairSonataReceived = pairSonataSent - initialPairSonataAmount;
        lusdReceived = lusdAmount - initialLUSDAmount;
        ethReceived = ethAmount - initialETHAmount;

        if (pairSonataSent > 0) pairSonata.transfer(_recipient, pairSonataSent);
        if (_doSendRewards) (lusdSent, ethSent) = _sendRewards(_recipient, lusdAmount, ethAmount);
    }

    function _sendRewards(address _recipient, uint256 _lusdAmount, uint256 _ethAmount)
        internal
        returns (uint256 lusdSent, uint256 ethSent)
    {
        if (_lusdAmount > 0) lusd.transfer(_recipient, _lusdAmount);
        if (_ethAmount > 0) {
            (bool success,) = payable(_recipient).call{value: _ethAmount}("");
            require(success, "UserProxy: eth-fail");
        }

        return (_lusdAmount, _ethAmount);
    }

    /// @inheritdoc IUserProxy
    function staked() external view returns (uint256) {
        return stakingV1.stakes(address(this));
    }

    receive() external payable {}
}
