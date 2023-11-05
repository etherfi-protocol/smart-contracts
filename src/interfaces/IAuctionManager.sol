// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface IAuctionManager {
    struct Bid {
        uint256 amount;
        uint64 bidderPubKeyIndex;
        address bidderAddress;
        bool isActive;
    }

    function initialize(address _nodeOperatorManagerContract) external;

    function getBidOwner(uint256 _bidId) external view returns (address);

    function numberOfActiveBids() external view returns (uint256);

    function isBidActive(uint256 _bidId) external view returns (bool);

    function createBid(
        uint256 _bidSize,
        uint256 _bidAmount
    ) external payable returns (uint256[] memory);

    function cancelBidBatch(uint256[] calldata _bidIds) external;

    function cancelBid(uint256 _bidId) external;

    function reEnterAuction(uint256 _bidId) external;

    function updateSelectedBidInformation(uint256 _bidId) external;

    function processAuctionFeeTransfer(uint256 _validatorId) external;

    function setStakingManagerContractAddress(
        address _stakingManagerContractAddress
    ) external;

    function setAccumulatedRevenueThreshold(uint128 _newThreshold) external;

    function updateAdmin(address _address, bool _isAdmin) external;
    function pauseContract() external;
    function unPauseContract() external;
    
    function transferAccumulatedRevenue() external;
}
