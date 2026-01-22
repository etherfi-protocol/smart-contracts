// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IPriorityWithdrawalQueue {
    /// @notice Withdrawal request struct stored as hash in EnumerableSet
    /// @param nonce Unique nonce to prevent hash collisions
    /// @param user The user who created the request
    /// @param amountOfEEth Original eETH amount requested
    /// @param shareOfEEth eETH shares at time of request
    /// @param creationTime Timestamp when request was created
    /// @param secondsToMaturity Time until request can be fulfilled
    /// @param secondsToDeadline Time after maturity until request expires
    struct WithdrawRequest {
        uint96 nonce;
        address user;
        uint128 amountOfEEth;
        uint128 shareOfEEth;
        uint40 creationTime;
        uint24 secondsToMaturity;
        uint24 secondsToDeadline;
    }

    /// @notice Configuration for withdrawal parameters
    /// @param allowWithdraws Whether withdrawals are currently allowed
    /// @param secondsToMaturity Time in seconds until a request can be fulfilled
    /// @param minimumSecondsToDeadline Minimum validity period after maturity
    /// @param minimumAmount Minimum eETH amount per withdrawal
    /// @param withdrawCapacity Maximum pending withdrawal amount allowed
    struct WithdrawConfig {
        bool allowWithdraws;
        uint24 secondsToMaturity;
        uint24 minimumSecondsToDeadline;
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
    function requestWithdraw(uint128 amountOfEEth, uint24 secondsToDeadline) external returns (bytes32 requestId);
    function requestWithdrawWithPermit(uint128 amountOfEEth, uint24 secondsToDeadline, PermitInput calldata permit) external returns (bytes32 requestId);
    function cancelWithdraw(WithdrawRequest calldata request) external returns (bytes32 requestId);
    function replaceWithdraw(WithdrawRequest calldata oldRequest, uint24 newSecondsToDeadline) external returns (bytes32 oldRequestId, bytes32 newRequestId);
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
    function updateWithdrawConfig(uint24 secondsToMaturity, uint24 minimumSecondsToDeadline, uint96 minimumAmount) external;
    function setWithdrawCapacity(uint256 capacity) external;
    function stopWithdraws() external;
    function invalidateRequest(WithdrawRequest calldata request) external;
    function validateRequest(bytes32 requestId) external;
    function finalizeRequests(bytes32 upToRequestId) external;
    function cancelUserWithdraws(WithdrawRequest[] calldata requests) external returns (bytes32[] memory);
    function pauseContract() external;
    function unPauseContract() external;
}
