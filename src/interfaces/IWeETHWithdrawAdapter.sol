// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./ILiquidityPool.sol";

interface IWeETHWithdrawAdapter {
    
    struct PermitInput {
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    /**
     * @notice Request withdrawal using weETH tokens
     * @param weETHAmount Amount of weETH to withdraw
     * @param recipient Address that will receive the WithdrawRequestNFT
     * @return requestId The ID of the created withdrawal request
     */
    function requestWithdraw(uint256 weETHAmount, address recipient) external returns (uint256 requestId);

    /**
     * @notice Request withdrawal using weETH tokens with permit (gasless approval)
     * @param weETHAmount Amount of weETH to withdraw
     * @param recipient Address that will receive the WithdrawRequestNFT
     * @param permit Permit data for weETH approval
     * @return requestId The ID of the created withdrawal request
     */
    function requestWithdrawWithPermit(
        uint256 weETHAmount, 
        address recipient, 
        PermitInput calldata permit
    ) external returns (uint256 requestId);



    /**
     * @notice Get the equivalent eETH amount for a given weETH amount
     * @param weETHAmount Amount of weETH
     * @return eETHAmount Equivalent amount of eETH
     */
    function getEETHByWeETH(uint256 weETHAmount) external view returns (uint256 eETHAmount);
}
