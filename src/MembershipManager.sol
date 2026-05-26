// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/IeETH.sol";
import "./interfaces/IMembershipManager.sol";
import "./interfaces/IMembershipNFT.sol";
import "./interfaces/ILiquidityPool.sol";
import "./interfaces/IEtherFiAdmin.sol";
import "./interfaces/IBlacklister.sol";
import "./utils/RolesLibrary.sol";

import "./libraries/GlobalIndexLibrary.sol";

import "forge-std/console.sol";

contract MembershipManager is Initializable, OwnableUpgradeable, PausableUpgradeable, UUPSUpgradeable, IMembershipManager, RolesLibrary {
    using SafeERC20 for IERC20;

    //--------------------------------------------------------------------------------------
    //---------------------------------  STATE-VARIABLES  ----------------------------------
    //--------------------------------------------------------------------------------------

    IeETH private DEPRECATED_eETH;
    ILiquidityPool private DEPRECATED_liquidityPool;
    IMembershipNFT private DEPRECATED_membershipNFT;
    address private DEPRECATED_treasury;
    address private DEPRECATED_protocolRevenueManager;

    mapping (uint256 => uint256) public allTimeHighDepositAmount;
    mapping (uint256 => TokenDeposit) public tokenDeposits;
    mapping (uint256 => TokenData) public tokenData;
    TierDeposit[] public tierDeposits;
    TierData[] public tierData;

    // [BEGIN] SLOT 261

    uint16 public pointsBoostFactor; // + (X / 10000) more points, if staking rewards are sacrificed
    uint16 public pointsGrowthRate; // + (X / 10000) kwei points are earned per ETH per day
    uint56 public minDepositGwei;
    uint8  public maxDepositTopUpPercent;

    uint16 private mintFee; // fee = 0.001 ETH * 'mintFee'
    uint16 private burnFee; // fee = 0.001 ETH * 'burnFee'
    uint16 private upgradeFee; // fee = 0.001 ETH * 'upgradeFee'
    uint8 private DEPRECATED_treasuryFeeSplitPercent;
    uint8 private DEPRECATED_protocolRevenueFeeSplitPercent;

    uint32 public topUpCooltimePeriod;
    uint32 public withdrawalLockBlocks;

    uint16 private fanBoostThreshold; // = 0.001 ETH * fanBoostThreshold
    uint16 private burnFeeWaiverPeriodInDays;

    // [END] SLOT 261 END

    uint128 private DEPRECATED_sharesReservedForRewards;

    address private DEPRECATED_admin;
    mapping(address => bool) private DEPRECATED_admins;

    // Phase 2
    TierVault[] public tierVaults;

    IEtherFiAdmin private DEPRECATED_etherFiAdmin;

    IeETH public immutable eETH;
    ILiquidityPool public immutable liquidityPool;
    IMembershipNFT public immutable membershipNFT;
    IEtherFiAdmin public immutable etherFiAdmin;
    IBlacklister public immutable blacklister;

    uint256 public constant BASIS_POINTS_DENOMINATOR = 10000;
    uint256 public constant FEE_UNIT = 0.001 ether;

    //--------------------------------------------------------------------------------------
    //-------------------------------------  EVENTS  ---------------------------------------
    //--------------------------------------------------------------------------------------

    event FundsMigrated(address indexed user, uint256 _tokenId, uint256 _amount, uint256 _eapPoints, uint40 _loyaltyPoints, uint40 _tierPoints);
    event NftUpdated(uint256 _tokenId, uint128 _amount, uint128 _amountSacrificedForBoostingPoints, uint40 _loyaltyPoints, uint40 _tierPoints, uint8 _tier, uint32 _prevTopUpTimestamp, uint96 _share);
    event NftUnwrappedForEEth(address indexed _user, uint256 indexed _tokenId, uint256 _amountOfEEth, uint40 _loyaltyPoints, uint256 _feeAmount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _eETH, address _liquidityPool, address _membershipNFT, address _etherFiAdmin, address _roleRegistry, address _blacklister) RolesLibrary(_roleRegistry) {
        eETH = IeETH(_eETH);
        liquidityPool = ILiquidityPool(_liquidityPool);
        membershipNFT = IMembershipNFT(_membershipNFT);
        etherFiAdmin = IEtherFiAdmin(_etherFiAdmin);
        blacklister = IBlacklister(_blacklister);
        _disableInitializers();
    }

    receive() external payable {}

    //--------------------------------------------------------------------------------------
    //----------------------------  STATE-CHANGING FUNCTIONS  ------------------------------
    //--------------------------------------------------------------------------------------

    error Deprecated();
    error WrongVersion();
    error InvalidEAPRollover();

    error InvalidAmount();
    error InsufficientBalance();

    function unwrapForEEthAndBurn(uint256 _tokenId) external whenNotPaused nonBlacklisted {
        _requireTokenOwner(_tokenId);

        uint40 loyaltyPoints = membershipNFT.loyaltyPointsOf(_tokenId);
        (uint256 totalBalance, uint256 feeAmount) = _withdrawAndBurn(_tokenId);

        // transfer 'eEthShares' of eETH to the owner
        IERC20(address(eETH)).safeTransfer(msg.sender, totalBalance - feeAmount);

        if (feeAmount > 0) {
            liquidityPool.withdraw(address(this), feeAmount);
        }

        emit NftUnwrappedForEEth(msg.sender, _tokenId, totalBalance - feeAmount, loyaltyPoints, feeAmount);
    }

    error ExceededMaxWithdrawal();
    error InvalidCaller();
    error TierLimitExceeded();
    error OutOfBound();
    error WrongTokenMinted();
    error UnexpectedTier();
    error OnlyTokenOwner();

    /// @notice Requests exchange of membership points tokens for ETH.
    /// @dev decrements the amount of eETH backing the membership NFT and calls requestWithdraw on the liquidity pool
    /// @param _tokenId The ID of the membership NFT.
    /// @param _amount The amount of membership tokens to exchange.
    /// @return uint256 ID of the withdraw request NFT
    function requestWithdraw(uint256 _tokenId, uint256 _amount) external whenNotPaused nonBlacklisted returns (uint256) {
        _requireTokenOwner(_tokenId);

        // prevent transfers for several blocks after a withdrawal to prevent frontrunning
        membershipNFT.incrementLock(_tokenId, withdrawalLockBlocks);

        claim(_tokenId);
        if (!membershipNFT.isWithdrawable(_tokenId, _amount)) revert ExceededMaxWithdrawal();

        uint256 prevAmount = ethAmountForVaultShare(tokenData[_tokenId].tier, tokenData[_tokenId].vaultShare);
        _updateAllTimeHighDepositOf(_tokenId);
        _withdraw(_tokenId, _amount);
        _applyUnwrapPenalty(_tokenId, prevAmount, _amount);

        // send EETH to recipient before requesting withdraw?
        IERC20(address(eETH)).safeIncreaseAllowance(address(liquidityPool), _amount);
        uint256 withdrawTokenId = liquidityPool.requestMembershipNFTWithdraw(address(msg.sender), _amount, uint64(0));

        _emitNftUpdateEvent(_tokenId);
        return withdrawTokenId;
    }

    /// @notice request to withdraw the entire balance of this NFT and burn it
    /// @dev burns the NFT and calls requestWithdraw on the liquidity pool
    /// @param _tokenId ID of the membership NFT to liquidate
    /// @return uint256 ID of the withdraw request NFT
    function requestWithdrawAndBurn(uint256 _tokenId) external whenNotPaused nonBlacklisted returns (uint256) {
        _requireTokenOwner(_tokenId);

        (uint256 totalBalance, uint256 feeAmount) = _withdrawAndBurn(_tokenId);

        IERC20(address(eETH)).safeIncreaseAllowance(address(liquidityPool), totalBalance);
        uint256 withdrawTokenId = liquidityPool.requestMembershipNFTWithdraw(msg.sender, totalBalance, feeAmount);
        
        return withdrawTokenId;
    }

    /// @notice Claims {points, staking rewards} and update the tier, if needed.
    /// @param _tokenId The ID of the membership NFT.
    /// @dev This function allows users to claim the rewards + a new tier, if eligible.
    function claim(uint256 _tokenId) public whenNotPaused nonBlacklisted {
        _claimPoints(_tokenId);

        uint8 oldTier = tokenData[_tokenId].tier;
        uint8 newTier = membershipNFT.claimableTier(_tokenId);
        if (oldTier != newTier) {
            _claimTier(_tokenId, oldTier, newTier);
        }
        _emitNftUpdateEvent(_tokenId);
    }

    function rebase(int128 _accruedRewards) external {
        if (msg.sender != address(etherFiAdmin)) revert InvalidCaller();
        uint256 ethRewardsPerEEthShareBeforeRebase = liquidityPool.amountForShare(1 ether);
        liquidityPool.rebase(_accruedRewards);
        uint256 ethRewardsPerEEthShareAfterRebase = liquidityPool.amountForShare(1 ether);

        // The balance of MembershipManager contract is used to reward ether.fan stakers (not eETH stakers)
        // Eth Rewards Amount per NFT = (eETH share amount of the NFT) * (total rewards ETH amount) / (total eETH share amount in ether.fan)
        uint256 etherFanEEthShares = eETH.shares(address(this));
        if (etherFanEEthShares == 0) return;
        uint256 thresholdAmount = fanBoostThresholdEthAmount();
        if (address(this).balance >= thresholdAmount) {
            uint256 mintedShare = liquidityPool.deposit{value: thresholdAmount}(address(this), address(0));
            ethRewardsPerEEthShareAfterRebase += 1 ether * thresholdAmount / etherFanEEthShares;
        }

        _distributeStakingRewardsV1(ethRewardsPerEEthShareBeforeRebase, ethRewardsPerEEthShareAfterRebase);
    }

    function claimBatch(uint256[] calldata _tokenIds) public whenNotPaused {
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            claim(_tokenIds[i]);
        }
    }

    function _distributeStakingRewardsV1(uint256 _ethRewardsPerEEthShareBeforeRebase, uint256 _ethRewardsPerEEthShareAfterRebase) internal {
        uint128[] memory vaultTotalPooledEEthShares = globalIndexLibrary.calculateVaultEEthShares(address(this), address(liquidityPool), _ethRewardsPerEEthShareBeforeRebase, _ethRewardsPerEEthShareAfterRebase);
        for (uint256 i = 0; i < tierDeposits.length; i++) {
            tierVaults[i].totalPooledEEthShares = vaultTotalPooledEEthShares[i];
        }
    }

    /// @dev set how many blocks a token is locked from trading for after withdrawing
    function setWithdrawalLockBlocks(uint32 _blocks) external onlyOperatingMultisig {
        withdrawalLockBlocks = _blocks;
    }

    //Pauses the contract
    function pauseContract() external onlyOperatingMultisig {
        _pause();
    }

    //Unpauses the contract
    function unPauseContract() external onlyOperatingMultisig {
        _unpause();
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------  INTERNAL FUNCTIONS   --------------------------------
    //--------------------------------------------------------------------------------------
    function _withdrawAndBurn(uint256 _tokenId) internal returns (uint256, uint256) {
        if (tokenData[_tokenId].version != 1) revert WrongVersion();

        uint8 tier = tokenData[_tokenId].tier;
        uint256 vaultShare = tokenData[_tokenId].vaultShare;
        uint256 ethAmount = ethAmountForVaultShare(tier, vaultShare);
        uint256 feeAmount = hasMetBurnFeeWaiverPeriod(_tokenId) ? 0 : uint256(burnFee) * FEE_UNIT;
        if (ethAmount < feeAmount) revert InsufficientBalance();

        _withdraw(_tokenId, ethAmount);
        delete tokenData[_tokenId];

        membershipNFT.burn(msg.sender, _tokenId, 1);

        _emitNftUpdateEvent(_tokenId);

        return (ethAmount, feeAmount);
    }

    function _withdraw(uint256 _tokenId, uint256 _amount) internal {
        if (membershipNFT.valueOf(_tokenId) < _amount) revert InsufficientBalance();
        if (tokenData[_tokenId].version != 1) revert WrongVersion();

        uint8 tier = tokenData[_tokenId].tier;
        uint256 vaultShare = vaultShareForEthAmount(tier, _amount);
        uint256 eEthShare = liquidityPool.sharesForAmount(_amount);

        _decrementTierVaultV1(tier, eEthShare, vaultShare);
        _decrementTokenVaultShareV1(_tokenId, vaultShare);        
    }

    // V1
    function _decrementTokenVaultShareV1(uint256 _tokenId, uint256 _share) internal {
        tokenData[_tokenId].vaultShare -= uint96(_share);
    }

    function _incrementTierVaultV1(uint8 _tier, uint256 _eEthShare, uint256 _vaultShare) internal {
        tierVaults[_tier].totalVaultShares += uint128(_vaultShare);
        tierVaults[_tier].totalPooledEEthShares += uint128(_eEthShare);
    }

    function _decrementTierVaultV1(uint8 _tier, uint256 _eEthShare, uint256 _vaultShare) internal {
        tierVaults[_tier].totalVaultShares -= uint128(_vaultShare);
        tierVaults[_tier].totalPooledEEthShares -= uint128(_eEthShare);
    }

    function _claimTier(uint256 _tokenId) internal {
        uint8 oldTier = tokenData[_tokenId].tier;
        uint8 newTier = membershipNFT.claimableTier(_tokenId);
        _claimTier(_tokenId, oldTier, newTier);
    }

    function _claimTier(uint256 _tokenId, uint8 _curTier, uint8 _newTier) internal {
        if (tokenData[_tokenId].tier != _curTier) revert UnexpectedTier();
        if (_curTier == _newTier) {
            return;
        }
        
        uint256 prevVaultShare = tokenData[_tokenId].vaultShare;
        uint256 eEthShare = eEthShareForVaultShare(_curTier, prevVaultShare);
        uint256 newVaultShare = vaultShareForEEthShare(_newTier, eEthShare);

        _decrementTierVaultV1(_curTier, eEthShare, prevVaultShare);
        _incrementTierVaultV1(_newTier, eEthShare, newVaultShare);
        tokenData[_tokenId].vaultShare = uint96(newVaultShare);
        tokenData[_tokenId].tier = _newTier;
    }

    /// @notice Claims the accrued membership {loyalty, tier} points.
    /// @param _tokenId The ID of the membership NFT.
    function _claimPoints(uint256 _tokenId) internal {
        TokenData storage token = tokenData[_tokenId];
        token.baseLoyaltyPoints = membershipNFT.loyaltyPointsOf(_tokenId);
        token.baseTierPoints = membershipNFT.tierPointsOf(_tokenId);
        token.prevPointsAccrualTimestamp = uint32(block.timestamp);
    }

    function eEthShareForVaultShare(uint8 _tier, uint256 _vaultShare) public view returns (uint256) {
        uint256 amount;
        if (tierVaults[_tier].totalVaultShares == 0) {
            amount = 0;
        } else {
            amount = (_vaultShare * tierVaults[_tier].totalPooledEEthShares) / tierVaults[_tier].totalVaultShares;
        }
        return amount;
    }

    function vaultShareForEEthShare(uint8 _tier, uint256 _eEthShare) public view returns (uint256) {
        uint256 vaultShare;
        if (tierVaults[_tier].totalPooledEEthShares == 0) {
            vaultShare = _eEthShare;
        } else {
            vaultShare = (_eEthShare * tierVaults[_tier].totalVaultShares) / tierVaults[_tier].totalPooledEEthShares;
        }
        return vaultShare;
    }

    function ethAmountForVaultShare(uint8 _tier, uint256 _vaultShare) public view returns (uint256) {
        uint256 eEthShare = eEthShareForVaultShare(_tier, _vaultShare);
        return liquidityPool.amountForShare(eEthShare);
    }

    function vaultShareForEthAmount(uint8 _tier, uint256 _ethAmount) public view returns (uint256) {
        uint256 eEthshare = liquidityPool.sharesForAmount(_ethAmount);
        return vaultShareForEEthShare(_tier, eEthshare);
    }

    function fanBoostThresholdEthAmount() public view returns (uint256) {
        return uint256(fanBoostThreshold) * FEE_UNIT;
    }

    function hasMetBurnFeeWaiverPeriod(uint256 _tokenId) public view returns (bool) {
        uint256 stakingPeriod = membershipNFT.tierPointsOf(_tokenId) / 24;
        return stakingPeriod >= burnFeeWaiverPeriodInDays;
    }

    function _updateAllTimeHighDepositOf(uint256 _tokenId) internal {
        allTimeHighDepositAmount[_tokenId] = membershipNFT.allTimeHighDepositOf(_tokenId);
    }

    function _requireTokenOwner(uint256 _tokenId) internal view {
        if (membershipNFT.balanceOfUser(msg.sender, _tokenId) != 1) revert OnlyTokenOwner();
    }

    function _min(uint256 _a, uint256 _b) internal pure returns (uint256) {
        return (_a > _b) ? _b : _a;
    }

    function _max(uint256 _a, uint256 _b) internal pure returns (uint256) {
        return (_a > _b) ? _a : _b;
    }

    /// @notice Applies the unwrap penalty.
    /// @dev Always lose at least a tier, possibly more depending on percentage of deposit withdrawn
    /// @param _tokenId The ID of the membership NFT.
    /// @param _prevAmount The amount of ETH that the NFT was holding
    /// @param _withdrawalAmount The amount of ETH that is being withdrawn
    function _applyUnwrapPenalty(uint256 _tokenId, uint256 _prevAmount, uint256 _withdrawalAmount) internal {
        TokenData storage token = tokenData[_tokenId];
        uint8 prevTier = token.tier > 0 ? token.tier - 1 : 0;
        uint40 curTierPoints = token.baseTierPoints;

        // point deduction if we kick back to start of previous tier
        uint40 degradeTierPenalty = curTierPoints - tierData[prevTier].requiredTierPoints;

        // point deduction if scaled proportional to withdrawal amount
        uint256 ratio = (BASIS_POINTS_DENOMINATOR * _withdrawalAmount) / _prevAmount;
        uint40 scaledTierPointsPenalty = uint40((ratio * curTierPoints) / BASIS_POINTS_DENOMINATOR);

        uint40 penalty = uint40(_max(degradeTierPenalty, scaledTierPointsPenalty));

        token.baseTierPoints -= penalty;
        _claimTier(_tokenId);
    }

    function _emitNftUpdateEvent(uint256 _tokenId) internal {
        uint128 amount = uint128(membershipNFT.valueOf(_tokenId));
        TokenData memory token = tokenData[_tokenId];
        emit NftUpdated(_tokenId, amount, 0,
                        token.baseLoyaltyPoints, token.baseTierPoints, token.tier,
                        token.prevTopUpTimestamp, token.vaultShare);
    }

    // Finds the corresponding for the tier points
    function tierForPoints(uint40 _tierPoints) public view returns (uint8) {
        uint8 tierId = 0;

        while (tierId < tierData.length && _tierPoints >= tierData[tierId].requiredTierPoints) {
            tierId++;
        }

        return tierId - 1;
    }

    function canTopUp(uint256 _tokenId, uint256 _totalAmount, uint128 _amount, uint128 _amountForPoints) public view returns (bool) {
        uint32 prevTopUpTimestamp = tokenData[_tokenId].prevTopUpTimestamp;
        if (block.timestamp - uint256(prevTopUpTimestamp) < topUpCooltimePeriod) return false;
        if (_totalAmount != _amount + _amountForPoints) return false;
        return true;
    }

    function numberOfTiers() external view returns (uint8) {
        return uint8(tierData.length);
    }

    function minimumAmountForMint() external view returns (uint256) {
        return uint256(1 gwei) * minDepositGwei;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyUpgradeTimelock {}

    //--------------------------------------------------------------------------------------
    //--------------------------------------  GETTER  --------------------------------------
    //--------------------------------------------------------------------------------------

    // returns (mintFeeAmount, burnFeeAmount, upgradeFeeAmount)
    function getFees() external view returns (uint256 mintFeeAmount, uint256 burnFeeAmount, uint256 upgradeFeeAmount) {
        return (uint256(mintFee) * FEE_UNIT, uint256(burnFee) * FEE_UNIT, uint256(upgradeFee) * FEE_UNIT);
    }

    function rewardsGlobalIndex(uint8 _tier) external view returns (uint256) {
        return tierData[_tier].rewardsGlobalIndex;
    }

    function getImplementation() external view returns (address) {
        return _getImplementation();
    }

    //--------------------------------------------------------------------------------------
    //------------------------------------  MODIFIER  --------------------------------------
    //--------------------------------------------------------------------------------------

    modifier nonBlacklisted() {
        blacklister.nonBlacklisted(msg.sender);
        _;
    }
}
