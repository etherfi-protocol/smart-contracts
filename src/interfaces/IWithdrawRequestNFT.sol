// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface IWithdrawRequestNFT {
    struct WithdrawRequest {
        uint96  amountOfEEth;
        uint96  shareOfEEth;
        bool    isValid;
        uint32  feeGwei;
    }

    function initialize(address _liquidityPoolAddress, address _eEthAddress, address _membershipManager) external;
    function requestWithdraw(uint96 amountOfEEth, uint96 shareOfEEth, address requester, uint256 fee) external payable returns (uint256);
    function claimWithdraw(uint256 requestId) external;

    function getRequest(uint256 requestId) external view returns (WithdrawRequest memory);
    function isFinalized(uint256 requestId) external view returns (bool);

    function invalidateRequest(uint256 requestId) external;
    function finalizeRequests(uint256 upperBound) external;
    function updateAdmin(address _address, bool _isAdmin) external;
}
