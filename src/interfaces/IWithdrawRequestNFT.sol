// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IWithdrawRequestNFT {
    struct WithdrawRequest {
        uint96  amountOfEEth;
        uint96  shareOfEEth;
        bool    isValid;
        uint32  feeGwei;
    }

    struct FinalizationCheckpoint {
        uint256 lastFinalizedRequestId;
        uint256 cachedShareValue;
    }

    function initialize(address _liquidityPoolAddress, address _eEthAddress, address _membershipManager) external;
    function requestWithdraw(uint96 amountOfEEth, uint96 shareOfEEth, address requester) external payable returns (uint32);
    function claimWithdraw(uint32 requestId, uint32 checkpointIndex) external;

    function getRequest(uint32 requestId) external view returns (WithdrawRequest memory);
    function isFinalized(uint32 requestId) external view returns (bool);

    function invalidateRequest(uint32 requestId) external;
    function finalizeRequests(uint32 lastRequestId) external;
    function finalizeRequests(uint256 lastRequestId, uint256 totalAmount) external;
}
