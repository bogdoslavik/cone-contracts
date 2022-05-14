// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "./Bribe.sol";
import "../../interface/IBribeFactory.sol";

contract BribeFactory is IBribeFactory {
  address public lastGauge;

  function createBribe(address[] memory _allowedRewardTokens) external override returns (address) {
    address _lastGauge = address(new Bribe(
        msg.sender,
        _allowedRewardTokens
      ));
    lastGauge = _lastGauge;
    return _lastGauge;
  }
}
