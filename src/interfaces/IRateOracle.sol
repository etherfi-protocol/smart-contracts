// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface IRateOracle {

    function getRate() external view returns (uint256);
    function setRate(uint256 _rate) external;
    function lastUpdated() external view returns (uint256);

}
