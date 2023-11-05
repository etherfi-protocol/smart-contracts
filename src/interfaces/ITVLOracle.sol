// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface ITVLOracle {

    function setTvl(uint256 _newTvl) external;
    function getTvl() external view returns (uint256 _currentTvl);
    function setTVLAggregator(address _tvlAggregator) external;

}