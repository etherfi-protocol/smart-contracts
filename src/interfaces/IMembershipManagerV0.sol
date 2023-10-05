// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface IMembershipManagerV0 {

    struct TokenDeposit {
        uint128 amounts;
        uint128 shares;
    }

    struct TokenData {
        uint96 rewardsLocalIndex;
        uint40 baseLoyaltyPoints;
        uint40 baseTierPoints;
        uint32 prevPointsAccrualTimestamp;
        uint32 prevTopUpTimestamp;
        uint8  tier;
        uint8  __gap;
    }

    struct TierDeposit {
        uint128 amounts;
        uint128 shares;
    }

    struct TierData {
        uint96 rewardsGlobalIndex;
        uint40 requiredTierPoints;
        uint24 weight;
        uint96  __gap;
    }

    // State-changing functions
    function initialize(address _eEthAddress, address _liquidityPoolAddress, address _membershipNft, address _treasury, address _protocolRevenueManager) external;

    function wrapEthForEap(uint256 _amount, uint256 _amountForPoint, uint32  _eapDepositBlockNumber, uint256 _snapshotEthAmount, uint256 _points, bytes32[] calldata _merkleProof) external payable returns (uint256);
    function wrapEth(uint256 _amount, uint256 _amountForPoint) external payable returns (uint256);

    function topUpDepositWithEth(uint256 _tokenId, uint128 _amount, uint128 _amountForPoints) external payable;

    function requestWithdraw(uint256 _tokenId, uint256 _amount) external returns (uint256);
    function requestWithdrawAndBurn(uint256 _tokenId) external returns (uint256);

    function claim(uint256 _tokenId) external;

    // Getter functions
    function tokenDeposits(uint256) external view returns (uint128, uint128);
    function tokenData(uint256) external view returns (uint96, uint40, uint40, uint32, uint32, uint8, uint8);
    function tierDeposits(uint256) external view returns (uint128, uint128);
    function tierData(uint256) external view returns (uint96, uint40, uint24, uint96);

    function rewardsGlobalIndex(uint8 _tier) external view returns (uint256);
    function allTimeHighDepositAmount(uint256 _tokenId) external view returns (uint256);
    function tierForPoints(uint40 _tierPoints) external view returns (uint8);
    function canTopUp(uint256 _tokenId, uint256 _totalAmount, uint128 _amount, uint128 _amountForPoints) external view returns (bool);
    function pointsBoostFactor() external view returns (uint16);
    function pointsGrowthRate() external view returns (uint16);
    function maxDepositTopUpPercent() external view returns (uint8);
    function numberOfTiers() external view returns (uint8);
    function getImplementation() external view returns (address);
    function sharesReservedForRewards() external view returns (uint128);
    function minimumAmountForMint() external view returns (uint256);

    // only Owner
    function setWithdrawalLockBlocks(uint32 _blocks) external;
    function updatePointsParams(uint16 _newPointsBoostFactor, uint16 _newPointsGrowthRate) external;
    function rebase(int128 _accruedRewards) external;
    function addNewTier(uint40 _requiredTierPoints, uint24 _weight) external returns (uint256);
    function updateTier(uint8 _tier, uint40 _requiredTierPoints, uint24 _weight) external;
    function setPoints(uint256 _tokenId, uint40 _loyaltyPoints, uint40 _tierPoints) external;
    function setPointsBatch(uint256[] calldata _tokenIds, uint40[] calldata _loyaltyPoints, uint40[] calldata _tierPoints) external;
    function recoverTierPointsForEap(uint256 _tokenId, uint32  _eapDepositBlockNumber) external;
    function recoverTierPointsForEapBatch(uint256[] calldata _tokenIds, uint32[] calldata _eapDepositBlockNumbers) external;
    function setMinDepositWei(uint56 _value) external;
    function setMaxDepositTopUpPercent(uint8 _percent) external;
    function setTopUpCooltimePeriod(uint32 _newWaitTime) external;
    function withdrawFees(uint256 _amount, address _recipient) external;
}
