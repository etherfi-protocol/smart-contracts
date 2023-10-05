// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "../../src/LiquidityPool.sol";

interface INodeOperatorManager {
    struct KeyData {
        uint64 totalKeys;
        uint64 keysUsed;
        bytes ipfsHash;
    }

    function getUserTotalKeys(
        address _user
    ) external view returns (uint64 totalKeys);

    function getNumKeysRemaining(
        address _user
    ) external view returns (uint64 numKeysRemaining);

    function isWhitelisted(
        address _user
    ) external view returns (bool whitelisted);

    function registerNodeOperator(
        bytes memory ipfsHash,
        uint64 totalKeys
    ) external;

    function batchMigrateNodeOperator(
        address[] memory _operator, 
        bytes[] memory _ipfsHash,
        uint64[] memory _totalKeys,
        uint64[] memory _keysUsed
    ) external; 

    function batchUpdateOperatorsApprovedTags(
        address[] memory _users, 
        LiquidityPool.SourceOfFunds[] memory _approvedTags, 
        bool[] memory _approvals
    ) external;

    function fetchNextKeyIndex(address _user) external returns (uint64);

    function isEligibleToRunValidatorsForSourceOfFund(address _operator, LiquidityPool.SourceOfFunds _source) external view returns (bool approved);

}
