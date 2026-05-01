// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./IWeETH.sol";

interface IPriorityWithdrawalQueue {
    /// @notice Withdrawal request struct stored as hash in EnumerableSet
    /// @param user The user who created the request
    /// @param amountOfEEth Original eETH amount requested
    /// @param shareOfEEth eETH shares at time of request
    /// @param amountWithFee ETH amount the user receives after fee deduction (amountOfEEth - fee)
    /// @param nonce Unique nonce to prevent hash collisions
    /// @param creationTime Timestamp when request was created
    struct WithdrawRequest {
        address user;           // 20 bytes
        uint96 amountOfEEth;    // 12 bytes | Slot 1 = 32 bytes
        uint96 shareOfEEth;     // 12 bytes
        uint96 amountWithFee;    // 12 bytes
        uint32 nonce;           // 4 bytes
        uint32 creationTime;    // 4 bytes  | Slot 2 = 32 bytes
    }

    struct PermitInput {
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    // User functions
    function requestWithdraw(uint96 amountOfEEth, uint96 amountWithFee) external returns (bytes32 requestId);
    function requestWithdrawWithPermit(uint96 amountOfEEth, uint96 amountWithFee, PermitInput calldata permit) external returns (bytes32 requestId);
    function requestWithdrawWithWeETH(uint96 weEthAmount, uint96 amountWithFee) external returns (bytes32 requestId);
    function requestWithdrawWithWeETHAndPermit(uint96 weEthAmount, uint96 amountWithFee, PermitInput calldata permit) external returns (bytes32 requestId);
    function weETH() external view returns (IWeETH);
    function cancelWithdraw(WithdrawRequest calldata request) external returns (bytes32 requestId);
    function claimWithdraw(WithdrawRequest calldata request) external;
    function batchClaimWithdraw(WithdrawRequest[] calldata requests) external;

    // View functions
    function getRequestId(WithdrawRequest calldata request) external pure returns (bytes32);
    function getRequestIds() external view returns (bytes32[] memory);
    function getClaimableAmount(WithdrawRequest calldata request) external view returns (uint256);
    function isWhitelisted(address user) external view returns (bool);
    function nonce() external view returns (uint32);
    function shareRemainderSplitToTreasuryInBps() external view returns (uint16);
    function ethAmountLockedForPriorityWithdrawal() external view returns (uint128);

    // Constants
    function MIN_DELAY() external view returns (uint32);
    function MIN_AMOUNT() external view returns (uint96);

    // Oracle/Solver functions
    function fulfillRequests(WithdrawRequest[] calldata requests) external;

    // Admin functions
    function addToWhitelist(address user) external;
    function removeFromWhitelist(address user) external;
    function batchUpdateWhitelist(address[] calldata users, bool[] calldata statuses) external;
    function invalidateRequests(WithdrawRequest[] calldata requests) external returns(bytes32[] memory);
    function updateShareRemainderSplitToTreasury(uint16 _shareRemainderSplitToTreasuryInBps) external;
    function handleRemainder(uint256 eEthAmount) external;
    function pauseContract() external;
    function unPauseContract() external;
    function pauseContractUntil() external;
    function unpauseContractUntil() external;

    // Immutables
    function treasury() external view returns (address);
}
