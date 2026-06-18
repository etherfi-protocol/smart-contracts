// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

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

    function setWithdrawalLockBlocks(uint32 _blocks) external;
}
