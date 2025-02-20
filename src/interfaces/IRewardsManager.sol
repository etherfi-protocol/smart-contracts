// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IRewardsManager {

    event RewardsAllocated(address token, address[] recipients, uint256[] amounts, uint256 blockNumber);
    event RewardsReverted(uint256 blockNumber);
    event RewardsClaimed(address token, address indexed recipient, uint256 amount);
    event RewardsRecipientUpdated(address earner, address recipient);

    function processRewards(address token, address[] calldata recipients, uint256[] calldata amounts, uint256 blockNumber) external;
    function claimRewards(address earner, address token) external;
    function updatePendingRewards(address token, address[] calldata recipients, uint256[] calldata amounts, uint256 blockNumber) external;
    function updateRewardsRecipient(address earner, address recipient) external;

    error IncorrectRole();
}