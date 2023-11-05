// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface IMembershipManager {

    struct TokenDeposit {
        uint128 amounts;
        uint128 shares;
    }

    struct TokenData {
        uint96 vaultShare;
        uint40 baseLoyaltyPoints;
        uint40 baseTierPoints;
        uint32 prevPointsAccrualTimestamp;
        uint32 prevTopUpTimestamp;
        uint8  tier;
        uint8  version;
    }

    // Used for V1
    struct TierVault {
        uint128 totalPooledEEthShares; // total share of eEth in the tier vault
        uint128 totalVaultShares; // total share of the tier vault
    }

    // Used for V0
    struct TierDeposit {
        uint128 amounts; // total pooled eth amount
        uint128 shares; // total pooled eEth shares
    }

    struct TierData {
        uint96 rewardsGlobalIndex;
        uint40 requiredTierPoints;
        uint24 weight;
        uint96  __gap;
    }

    // State-changing functions
    function wrapEthForEap(uint256 _amount, uint256 _amountForPoint, uint32  _eapDepositBlockNumber, uint256 _snapshotEthAmount, uint256 _points, bytes32[] calldata _merkleProof) external payable returns (uint256);
    function wrapEth(uint256 _amount, uint256 _amountForPoint) external payable returns (uint256);
    function wrapEth(uint256 _amount, uint256 _amountForPoint, address _referral) external payable returns (uint256);

    function topUpDepositWithEth(uint256 _tokenId, uint128 _amount, uint128 _amountForPoints) external payable;

    function requestWithdraw(uint256 _tokenId, uint256 _amount) external returns (uint256);
    function requestWithdrawAndBurn(uint256 _tokenId) external returns (uint256);

    function claim(uint256 _tokenId) external;

    function migrateFromV0ToV1(uint256 _tokenId) external;

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
    function minimumAmountForMint() external view returns (uint256);

    function eEthShareForVaultShare(uint8 _tier, uint256 _vaultShare) external view returns (uint256);
    function vaultShareForEEthShare(uint8 _tier, uint256 _eEthShare) external view returns (uint256);
    function ethAmountForVaultShare(uint8 _tier, uint256 _vaultShare) external view returns (uint256);
    function vaultShareForEthAmount(uint8 _tier, uint256 _ethAmount) external view returns (uint256);

    // only Owner
    function initializeOnUpgrade(address _etherFiAdminAddress, uint256 _fanBoostThresholdAmount, uint16 _burnFeeWaiverPeriodInDays) external;

    function setWithdrawalLockBlocks(uint32 _blocks) external;
    function updatePointsParams(uint16 _newPointsBoostFactor, uint16 _newPointsGrowthRate) external;
    function rebase(int128 _accruedRewards) external;
    function addNewTier(uint40 _requiredTierPoints, uint24 _weight) external;
    function updateTier(uint8 _tier, uint40 _requiredTierPoints, uint24 _weight) external;
    function setPoints(uint256 _tokenId, uint40 _loyaltyPoints, uint40 _tierPoints) external;
    function setDepositAmountParams(uint56 _minDepositGwei, uint8 _maxDepositTopUpPercent) external;
    function setTopUpCooltimePeriod(uint32 _newWaitTime) external;
    function updateAdmin(address _address, bool _isAdmin) external;
    function pauseContract() external;
    function unPauseContract() external;
}
