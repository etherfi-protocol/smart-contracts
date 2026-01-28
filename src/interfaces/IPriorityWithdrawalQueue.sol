// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IPriorityWithdrawalQueue {
    /// @notice Withdrawal request struct stored as hash in EnumerableSet
    /// @param nonce Unique nonce to prevent hash collisions
    /// @param user The user who created the request
    /// @param amountOfEEth Original eETH amount requested
    /// @param shareOfEEth eETH shares at time of request
    /// @param creationTime Timestamp when request was created
    struct WithdrawRequest {
        uint96 nonce;
        address user;
        uint128 amountOfEEth;
        uint128 shareOfEEth;
        uint40 creationTime;
    }

    /// @notice Configuration for withdrawal parameters
    /// @param minDelay Minimum delay in seconds before a request can be fulfilled
    /// @param creationTime Timestamp when the config was last updated
    /// @param minimumAmount Minimum eETH amount per withdrawal
    /// @param withdrawCapacity Maximum pending withdrawal amount allowed
    struct WithdrawConfig {
        uint24 minDelay;
        uint40 creationTime;
        uint96 minimumAmount;
        uint256 withdrawCapacity;
    }

    struct PermitInput {
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    // User functions
    function requestWithdraw(uint128 amountOfEEth) external returns (bytes32 requestId);
    function requestWithdrawWithPermit(uint128 amountOfEEth, PermitInput calldata permit) external returns (bytes32 requestId);
    function cancelWithdraw(WithdrawRequest calldata request) external returns (bytes32 requestId);
    function claimWithdraw(WithdrawRequest calldata request) external;
    function batchClaimWithdraw(WithdrawRequest[] calldata requests) external;

    // View functions
    function getRequestId(WithdrawRequest calldata request) external pure returns (bytes32);
    function getRequestIds() external view returns (bytes32[] memory);
    function getClaimableAmount(WithdrawRequest calldata request) external view returns (uint256);
    function isWhitelisted(address user) external view returns (bool);
    function nonce() external view returns (uint96);
    function withdrawConfig() external view returns (WithdrawConfig memory);

    // Oracle/Solver functions
    function fulfillRequests(WithdrawRequest[] calldata requests) external;

    // Admin functions
    function addToWhitelist(address user) external;
    function removeFromWhitelist(address user) external;
    function batchUpdateWhitelist(address[] calldata users, bool[] calldata statuses) external;
    function updateWithdrawConfig(uint24 minDelay, uint96 minimumAmount) external;
    function setWithdrawCapacity(uint256 capacity) external;
    function invalidateRequests(WithdrawRequest[] calldata requests) external returns(bytes32[] memory);
    function updateShareRemainderSplitToTreasury(uint16 _shareRemainderSplitToTreasuryInBps) external;
    function handleRemainder(uint256 eEthAmount) external;
    function pauseContract() external;
    function unPauseContract() external;

    // Immutables
    function treasury() external view returns (address);
    function shareRemainderSplitToTreasuryInBps() external view returns (uint16);
}
