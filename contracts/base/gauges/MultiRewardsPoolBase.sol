// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "../../interface/IERC20.sol";
import "../../lib/Math.sol";
import "../Reentrancy.sol";
import "../../lib/SafeERC20.sol";
import "../../lib/CheckpointLib.sol";

abstract contract MultiRewardsPoolBase is Reentrancy {
  using SafeERC20 for IERC20;
  using CheckpointLib for mapping(uint => CheckpointLib.Checkpoint);

  /// @dev The LP token that needs to be staked for rewards
  address public immutable underlying;

  uint public derivedSupply;
  mapping(address => uint) public derivedBalances;

  /// @dev Rewards are released over 7 days
  uint internal constant DURATION = 7 days;
  uint internal constant PRECISION = 10 ** 18;
  uint internal constant MAX_REWARD_TOKENS = 10;

  /// Default snx staking contract implementation
  /// https://github.com/Synthetixio/synthetix/blob/develop/contracts/StakingRewards.sol

  /// @dev Reward rate with precision 1e18
  mapping(address => uint) public rewardRate;
  mapping(address => uint) public periodFinish;
  mapping(address => uint) public lastUpdateTime;
  mapping(address => uint) public rewardPerTokenStored;

  mapping(address => mapping(address => uint)) public lastEarn;
  mapping(address => mapping(address => uint)) public userRewardPerTokenStored;

  uint public totalSupply;
  mapping(address => uint) public balanceOf;

  address[] public rewardTokens;
  mapping(address => bool) public isReward;

  /// @notice A record of balance checkpoints for each account, by index
  mapping(address => mapping(uint => CheckpointLib.Checkpoint)) public checkpoints;
  /// @notice The number of checkpoints for each account
  mapping(address => uint) public numCheckpoints;
  /// @notice A record of balance checkpoints for each token, by index
  mapping(uint => CheckpointLib.Checkpoint) public supplyCheckpoints;
  /// @notice The number of checkpoints
  uint public supplyNumCheckpoints;
  /// @notice A record of balance checkpoints for each token, by index
  mapping(address => mapping(uint => CheckpointLib.Checkpoint)) public rewardPerTokenCheckpoints;
  /// @notice The number of checkpoints for each token
  mapping(address => uint) public rewardPerTokenNumCheckpoints;

  event Deposit(address indexed from, uint amount);
  event Withdraw(address indexed from, uint amount);
  event NotifyReward(address indexed from, address indexed reward, uint amount);
  event ClaimRewards(address indexed from, address indexed reward, uint amount);

  constructor(address _stake) {
    underlying = _stake;
  }

  //**************************************************************************
  //************************ VIEWS *******************************************
  //**************************************************************************

  function rewardTokensLength() external view returns (uint) {
    return rewardTokens.length;
  }

  function rewardPerToken(address token) external view returns (uint) {
    return _rewardPerToken(token);
  }

  function _rewardPerToken(address token) internal view returns (uint) {
    if (derivedSupply == 0) {
      return rewardPerTokenStored[token];
    }
    return rewardPerTokenStored[token]
    + (
    (_lastTimeRewardApplicable(token) - Math.min(lastUpdateTime[token], periodFinish[token]))
    * rewardRate[token]
    / derivedSupply
    );
  }

  function derivedBalance(address account) external view returns (uint) {
    return _derivedBalance(account);
  }

  function left(address token) external view returns (uint) {
    if (block.timestamp >= periodFinish[token]) return 0;
    uint _remaining = periodFinish[token] - block.timestamp;
    return _remaining * rewardRate[token] / PRECISION;
  }

  function earned(address token, address account) external view returns (uint) {
    return _earned(token, account);
  }

  //**************************************************************************
  //************************ USER ACTIONS ************************************
  //**************************************************************************

  function deposit(uint amount) external virtual;

  function _deposit(uint amount) internal virtual lock {
    require(amount > 0, "Zero amount");

    _updateRewardForAllTokens();

    IERC20(underlying).safeTransferFrom(msg.sender, address(this), amount);
    totalSupply += amount;
    balanceOf[msg.sender] += amount;

    uint __derivedBalance = derivedBalances[msg.sender];
    derivedSupply -= __derivedBalance;
    __derivedBalance = _derivedBalance(msg.sender);
    derivedBalances[msg.sender] = __derivedBalance;
    derivedSupply += __derivedBalance;

    _writeCheckpoint(msg.sender, __derivedBalance);
    _writeSupplyCheckpoint();

    emit Deposit(msg.sender, amount);
  }

  function withdraw(uint amount) external virtual;

  function _withdraw(uint amount) internal lock virtual {
    _updateRewardForAllTokens();

    totalSupply -= amount;
    balanceOf[msg.sender] -= amount;
    IERC20(underlying).safeTransfer(msg.sender, amount);

    uint __derivedBalance = derivedBalances[msg.sender];
    derivedSupply -= __derivedBalance;
    __derivedBalance = _derivedBalance(msg.sender);
    derivedBalances[msg.sender] = __derivedBalance;
    derivedSupply += __derivedBalance;

    _writeCheckpoint(msg.sender, __derivedBalance);
    _writeSupplyCheckpoint();

    emit Withdraw(msg.sender, amount);
  }

  function getReward(address account, address[] memory tokens) external virtual;

  function _getReward(address account, address[] memory tokens) internal lock virtual {
    require(msg.sender == account, "Forbidden");

    for (uint i = 0; i < tokens.length; i++) {
      (rewardPerTokenStored[tokens[i]], lastUpdateTime[tokens[i]]) = _updateRewardPerToken(tokens[i]);

      uint _reward = _earned(tokens[i], account);
      lastEarn[tokens[i]][account] = block.timestamp;
      userRewardPerTokenStored[tokens[i]][account] = rewardPerTokenStored[tokens[i]];
      if (_reward > 0) {
        IERC20(tokens[i]).safeTransfer(account, _reward);
      }

      emit ClaimRewards(msg.sender, tokens[i], _reward);
    }

    uint __derivedBalance = derivedBalances[account];
    derivedSupply -= __derivedBalance;
    __derivedBalance = _derivedBalance(account);
    derivedBalances[account] = __derivedBalance;
    derivedSupply += __derivedBalance;

    _writeCheckpoint(account, __derivedBalance);
    _writeSupplyCheckpoint();
  }

  //**************************************************************************
  //************************ REWARDS CALCULATIONS ****************************
  //**************************************************************************

  // earned is an estimation, it won't be exact till the supply > rewardPerToken calculations have run
  function _earned(address token, address account) internal view returns (uint) {
    // zero checkpoints means zero deposits
    if (numCheckpoints[account] == 0) {
      return 0;
    }
    // last claim rewards time
    uint _startTimestamp = Math.max(lastEarn[token][account], rewardPerTokenCheckpoints[token][0].timestamp);

    // find an index of the balance that the user had on the last claim
    uint _startIndex = _getPriorBalanceIndex(account, _startTimestamp);
    uint _endIndex = numCheckpoints[account] - 1;

    uint reward = 0;

    // calculate previous snapshots if exist
    if (_endIndex > 0) {
      for (uint i = _startIndex; i <= _endIndex - 1; i++) {
        CheckpointLib.Checkpoint memory cp0 = checkpoints[account][i];
        CheckpointLib.Checkpoint memory cp1 = checkpoints[account][i + 1];
        (uint _rewardPerTokenStored0,) = _getPriorRewardPerToken(token, cp0.timestamp);
        (uint _rewardPerTokenStored1,) = _getPriorRewardPerToken(token, cp1.timestamp);
        reward += cp0.value * (_rewardPerTokenStored1 - _rewardPerTokenStored0) / PRECISION;
      }
    }

    CheckpointLib.Checkpoint memory cp = checkpoints[account][_endIndex];
    (uint _rewardPerTokenStored,) = _getPriorRewardPerToken(token, cp.timestamp);
    reward += cp.value * (_rewardPerToken(token) - Math.max(_rewardPerTokenStored, userRewardPerTokenStored[token][account])) / PRECISION;
    return reward;
  }

  function _derivedBalance(address account) internal virtual view returns (uint) {
    // assume to be implemented in a parent contract
    return balanceOf[account];
  }

  function batchRewardPerToken(address token, uint maxRuns) external {
    (rewardPerTokenStored[token], lastUpdateTime[token]) = _batchRewardPerToken(token, maxRuns);
  }

  function _batchRewardPerToken(address token, uint maxRuns) internal returns (uint, uint) {
    uint _startTimestamp = lastUpdateTime[token];
    uint reward = rewardPerTokenStored[token];

    if (supplyNumCheckpoints == 0) {
      return (reward, _startTimestamp);
    }

    if (rewardRate[token] == 0) {
      return (reward, block.timestamp);
    }

    uint _startIndex = _getPriorSupplyIndex(_startTimestamp);
    uint _endIndex = Math.min(supplyNumCheckpoints - 1, maxRuns);

    for (uint i = _startIndex; i < _endIndex; i++) {
      CheckpointLib.Checkpoint memory sp0 = supplyCheckpoints[i];
      if (sp0.value > 0) {
        CheckpointLib.Checkpoint memory sp1 = supplyCheckpoints[i + 1];
        (uint _reward, uint _endTime) = _calcRewardPerToken(token, sp1.timestamp, sp0.timestamp, sp0.value, _startTimestamp);
        reward += _reward;
        _writeRewardPerTokenCheckpoint(token, reward, _endTime);
        _startTimestamp = _endTime;
      }
    }

    return (reward, _startTimestamp);
  }

  function _calcRewardPerToken(
    address token,
    uint lastSupplyTs1,
    uint lastSupplyTs0,
    uint supply,
    uint startTimestamp
  ) internal view returns (uint, uint) {
    uint endTime = Math.max(lastSupplyTs1, startTimestamp);
    uint _periodFinish = periodFinish[token];
    return (
    (Math.min(endTime, _periodFinish) - Math.min(Math.max(lastSupplyTs0, startTimestamp), _periodFinish))
    * rewardRate[token] / supply
    , endTime);
  }

  function _updateRewardForAllTokens() internal {
    uint length = rewardTokens.length;
    for (uint i; i < length; i++) {
      address token = rewardTokens[i];
      (rewardPerTokenStored[token], lastUpdateTime[token]) = _updateRewardPerToken(token);
    }
  }

  function _updateRewardPerToken(address token) internal returns (uint, uint) {
    uint _startTimestamp = lastUpdateTime[token];
    uint reward = rewardPerTokenStored[token];

    if (supplyNumCheckpoints == 0) {
      return (reward, _startTimestamp);
    }

    if (rewardRate[token] == 0) {
      return (reward, block.timestamp);
    }
    uint _startIndex = _getPriorSupplyIndex(_startTimestamp);
    uint _endIndex = supplyNumCheckpoints - 1;

    if (_endIndex > 0) {
      for (uint i = _startIndex; i <= _endIndex - 1; i++) {
        CheckpointLib.Checkpoint memory sp0 = supplyCheckpoints[i];
        if (sp0.value > 0) {
          CheckpointLib.Checkpoint memory sp1 = supplyCheckpoints[i + 1];
          (uint _reward, uint _endTime) = _calcRewardPerToken(token, sp1.timestamp, sp0.timestamp, sp0.value, _startTimestamp);
          reward += _reward;
          _writeRewardPerTokenCheckpoint(token, reward, _endTime);
          _startTimestamp = _endTime;
        }
      }
    }

    CheckpointLib.Checkpoint memory sp = supplyCheckpoints[_endIndex];
    if (sp.value > 0) {
      (uint _reward,) = _calcRewardPerToken(token, _lastTimeRewardApplicable(token), Math.max(sp.timestamp, _startTimestamp), sp.value, _startTimestamp);
      reward += _reward;
      _writeRewardPerTokenCheckpoint(token, reward, block.timestamp);
      _startTimestamp = block.timestamp;
    }

    return (reward, _startTimestamp);
  }

  /// @dev Returns the last time the reward was modified or periodFinish if the reward has ended
  function _lastTimeRewardApplicable(address token) internal view returns (uint) {
    return Math.min(block.timestamp, periodFinish[token]);
  }

  //**************************************************************************
  //************************ NOTIFY ******************************************
  //**************************************************************************

  function notifyRewardAmount(address token, uint amount) external virtual;

  function _notifyRewardAmount(address token, uint amount) internal lock virtual {
    require(amount > 0, "Zero amount");
    if (rewardRate[token] == 0) {
      _writeRewardPerTokenCheckpoint(token, 0, block.timestamp);
    }
    (rewardPerTokenStored[token], lastUpdateTime[token]) = _updateRewardPerToken(token);

    if (block.timestamp >= periodFinish[token]) {
      IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
      rewardRate[token] = amount * PRECISION / DURATION;
    } else {
      uint _remaining = periodFinish[token] - block.timestamp;
      uint _left = _remaining * rewardRate[token];
      // not sure what the reason was in the original solidly implementation for this restriction
      // however, by design probably it is a good idea against human errors
      require(amount > _left / PRECISION, "Amount should be higher than remaining rewards");
      IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
      rewardRate[token] = (amount * PRECISION + _left) / DURATION;
    }
    require(rewardRate[token] > 0, "Zero reward rate");
    uint balance = IERC20(token).balanceOf(address(this));
    require(rewardRate[token] / PRECISION <= balance / DURATION, "Provided reward too high");
    periodFinish[token] = block.timestamp + DURATION;
    if (!isReward[token]) {
      require(rewardTokens.length < MAX_REWARD_TOKENS, "Too many reward tokens");
      isReward[token] = true;
      rewardTokens.push(token);
    }

    emit NotifyReward(msg.sender, token, amount);
  }

  //**************************************************************************
  //************************ CHECKPOINTS *************************************
  //**************************************************************************

  function getPriorBalanceIndex(address account, uint timestamp) external view returns (uint) {
    return _getPriorBalanceIndex(account, timestamp);
  }

  /// @notice Determine the prior balance for an account as of a block number
  /// @dev Block number must be a finalized block or else this function will revert to prevent misinformation.
  /// @param account The address of the account to check
  /// @param timestamp The timestamp to get the balance at
  /// @return The balance the account had as of the given block
  function _getPriorBalanceIndex(address account, uint timestamp) internal view returns (uint) {
    uint nCheckpoints = numCheckpoints[account];
    if (nCheckpoints == 0) {
      return 0;
    }
    return checkpoints[account].findLowerIndex(nCheckpoints, timestamp);
  }

  function getPriorSupplyIndex(uint timestamp) external view returns (uint) {
    return _getPriorSupplyIndex(timestamp);
  }

  function _getPriorSupplyIndex(uint timestamp) internal view returns (uint) {
    uint nCheckpoints = supplyNumCheckpoints;
    if (nCheckpoints == 0) {
      return 0;
    }
    return supplyCheckpoints.findLowerIndex(nCheckpoints, timestamp);
  }

  function getPriorRewardPerToken(address token, uint timestamp) external view returns (uint, uint) {
    return _getPriorRewardPerToken(token, timestamp);
  }

  function _getPriorRewardPerToken(address token, uint timestamp) internal view returns (uint, uint) {
    uint nCheckpoints = rewardPerTokenNumCheckpoints[token];
    if (nCheckpoints == 0) {
      return (0, 0);
    }
    mapping(uint => CheckpointLib.Checkpoint) storage cps = rewardPerTokenCheckpoints[token];
    uint lower = cps.findLowerIndex(nCheckpoints, timestamp);
    CheckpointLib.Checkpoint memory cp = cps[lower];
    return (cp.value, cp.timestamp);
  }

  function _writeCheckpoint(address account, uint balance) internal {
    uint _timestamp = block.timestamp;
    uint _nCheckPoints = numCheckpoints[account];

    if (_nCheckPoints > 0 && checkpoints[account][_nCheckPoints - 1].timestamp == _timestamp) {
      checkpoints[account][_nCheckPoints - 1].value = balance;
    } else {
      checkpoints[account][_nCheckPoints] = CheckpointLib.Checkpoint(_timestamp, balance);
      numCheckpoints[account] = _nCheckPoints + 1;
    }
  }

  function _writeRewardPerTokenCheckpoint(address token, uint reward, uint timestamp) internal {
    uint _nCheckPoints = rewardPerTokenNumCheckpoints[token];

    if (_nCheckPoints > 0 && rewardPerTokenCheckpoints[token][_nCheckPoints - 1].timestamp == timestamp) {
      rewardPerTokenCheckpoints[token][_nCheckPoints - 1].value = reward;
    } else {
      rewardPerTokenCheckpoints[token][_nCheckPoints] = CheckpointLib.Checkpoint(timestamp, reward);
      rewardPerTokenNumCheckpoints[token] = _nCheckPoints + 1;
    }
  }

  function _writeSupplyCheckpoint() internal {
    uint _nCheckPoints = supplyNumCheckpoints;
    uint _timestamp = block.timestamp;

    if (_nCheckPoints > 0 && supplyCheckpoints[_nCheckPoints - 1].timestamp == _timestamp) {
      supplyCheckpoints[_nCheckPoints - 1].value = derivedSupply;
    } else {
      supplyCheckpoints[_nCheckPoints] = CheckpointLib.Checkpoint(_timestamp, derivedSupply);
      supplyNumCheckpoints = _nCheckPoints + 1;
    }
  }
}