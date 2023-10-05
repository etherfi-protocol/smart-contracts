// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface ITreasury {
    function withdraw(uint256 _amount, address _to) external;
}
